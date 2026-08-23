$ErrorActionPreference = 'Stop'

$root = (Get-Location).Path
$skinDir = Join-Path $root 'res\skin'
$actorDir = Join-Path $root 'res\actor'
$effectDir = Join-Path $root 'res\effect'

function New-ResourceObject($file, $kind, $baseDir) {
    [pscustomobject]@{
        Kind     = $kind
        FullName = $file.FullName
        Rel      = ($file.FullName.Substring($root.Length + 1) -replace '\\', '/')
        LocalRel = if ($baseDir) { ($file.FullName.Substring($baseDir.Length + 1) -replace '\\', '/') } else { ($file.FullName.Substring($root.Length + 1) -replace '\\', '/') }
        Name     = $file.Name
        Base     = [IO.Path]::GetFileNameWithoutExtension($file.Name)
        Ext      = $file.Extension.ToLowerInvariant()
    }
}

function New-NameMap($files) {
    $map = @{}
    foreach ($file in $files) {
        if (!$map.ContainsKey($file.Name)) {
            $map[$file.Name] = New-Object System.Collections.Generic.List[object]
        }
        $map[$file.Name].Add($file) | Out-Null
    }
    return $map
}

function New-BaseMap($files) {
    $map = @{}
    foreach ($file in $files) {
        if (!$map.ContainsKey($file.Base)) {
            $map[$file.Base] = New-Object System.Collections.Generic.List[object]
        }
        $map[$file.Base].Add($file) | Out-Null
    }
    return $map
}

function Get-ScanText($path) {
    try {
        $bytes = [IO.File]::ReadAllBytes($path)
        if ($bytes.Length -eq 0) {
            return ''
        }
        return ([Text.Encoding]::UTF8.GetString($bytes) + "`n" + [Text.Encoding]::Default.GetString($bytes))
    } catch {
        return ''
    }
}

function Resolve-ResourceToken($token) {
    $clean = ($token -replace '\\', '/').Trim()
    $clean = $clean.Trim('"')
    $clean = $clean.Trim("'")
    $clean = $clean.Trim(' ', ',', ';', ')', ']', '}', '(', '[', '{')
    $name = @($clean -split '[/\\]')[-1]
    if ($script:resourcesByName.ContainsKey($name)) {
        return @($script:resourcesByName[$name].ToArray())
    }
    foreach ($knownName in $script:resourcesByName.Keys) {
        if ($clean.EndsWith($knownName, [StringComparison]::OrdinalIgnoreCase)) {
            return @($script:resourcesByName[$knownName].ToArray())
        }
    }
    return @()
}

function Add-UsedResource($file, $why, $via) {
    if (!$script:usedResources.ContainsKey($file.Rel)) {
        $script:usedResources[$file.Rel] = $true
        $script:queue.Enqueue($file) | Out-Null
    }
    if (!$script:reasons.ContainsKey($file.Rel)) {
        $script:reasons[$file.Rel] = New-Object System.Collections.Generic.List[string]
    }
    $reason = if ($via) { "$why <= $via" } else { $why }
    if (!$script:reasons[$file.Rel].Contains($reason)) {
        $script:reasons[$file.Rel].Add($reason) | Out-Null
    }
}

if (!(Test-Path -LiteralPath $skinDir)) {
    throw "res/skin not found: $skinDir"
}

$skinFiles = @(Get-ChildItem -LiteralPath $skinDir -Recurse -File | ForEach-Object { New-ResourceObject $_ 'skin' $skinDir })
$resourceFiles = New-Object System.Collections.Generic.List[object]
$skinFiles | ForEach-Object { $resourceFiles.Add($_) | Out-Null }

$actorFiles = @()
if (Test-Path -LiteralPath $actorDir) {
    $actorFiles = @(Get-ChildItem -LiteralPath $actorDir -Recurse -File -Filter *.actor | ForEach-Object { New-ResourceObject $_ 'actor' $actorDir })
    $actorFiles | ForEach-Object { $resourceFiles.Add($_) | Out-Null }
}

if (Test-Path -LiteralPath $effectDir) {
    Get-ChildItem -LiteralPath $effectDir -Recurse -File -Filter *.effect | ForEach-Object {
        $resourceFiles.Add((New-ResourceObject $_ 'effect' $effectDir)) | Out-Null
    }
}

$script:resourcesByName = New-NameMap $resourceFiles
$skinByName = New-NameMap $skinFiles
$actorByBase = New-BaseMap $actorFiles
$actorKeys = @($actorByBase.Keys | Where-Object { $_.Length -ge 5 } | Sort-Object Length -Descending -Unique | ForEach-Object { [regex]::Escape($_) })
$actorBasePattern = if ($actorKeys.Count -gt 0) { '(?i)(?<![A-Za-z0-9_])(' + ($actorKeys -join '|') + ')(?![A-Za-z0-9_])' } else { $null }
$skinNameKeys = @($skinByName.Keys | Sort-Object Length -Descending -Unique | ForEach-Object { [regex]::Escape($_) })
$skinNamePattern = if ($skinNameKeys.Count -gt 0) { '(?i)(' + ($skinNameKeys -join '|') + ')' } else { $null }
$resourceTokenRegex = [regex]'(?i)([^\s";,()\[\]{}<>:=]+\.(?:actor|mesh|png|anim|skin|skel|effect|tga))'

$script:usedResources = @{}
$script:reasons = @{}
$script:queue = New-Object System.Collections.Queue

$businessExtensions = @('.lua', '.csv', '.cfg', '.json', '.layout', '.xml', '.txt', '.ini', '.table', '.proto')
$businessFiles = @(Get-ChildItem -LiteralPath $root -Recurse -File -Force | Where-Object {
    $rel = ($_.FullName.Substring($root.Length + 1) -replace '\\', '/')
    $rel -notlike 'res/skin/*' -and
    $rel -notlike 'res/actor/*' -and
    $rel -notlike 'res/effect/*' -and
    $rel -notlike 'Task/*' -and
    $rel -notlike 'tasks/*' -and
    $rel -notlike '.git/*' -and
    $rel -notlike '.agents/*' -and
    $rel -notlike '.codex/*' -and
    ($businessExtensions -contains $_.Extension.ToLowerInvariant())
})

foreach ($businessFile in $businessFiles) {
    $rel = ($businessFile.FullName.Substring($root.Length + 1) -replace '\\', '/')
    $text = Get-ScanText $businessFile.FullName

    foreach ($match in $resourceTokenRegex.Matches($text)) {
        foreach ($resource in Resolve-ResourceToken $match.Groups[1].Value) {
            Add-UsedResource $resource "business explicit: $rel" $match.Groups[1].Value
        }
    }

    if ($actorBasePattern) {
        foreach ($match in [regex]::Matches($text, $actorBasePattern)) {
            $base = $match.Groups[1].Value
            if (!$actorByBase.ContainsKey($base)) {
                continue
            }
            foreach ($actor in $actorByBase[$base].ToArray()) {
                Add-UsedResource $actor "business actor basename: $rel" $base
                $showBase = $base + '_show'
                if ($actorByBase.ContainsKey($showBase)) {
                    foreach ($showActor in $actorByBase[$showBase].ToArray()) {
                        Add-UsedResource $showActor "dynamic actor_show supplement: $rel" $showBase
                    }
                }
            }
        }
    }
}

$processed = @{}
while ($script:queue.Count -gt 0) {
    $current = $script:queue.Dequeue()
    if ($processed.ContainsKey($current.Rel)) {
        continue
    }
    $processed[$current.Rel] = $true
    $text = Get-ScanText $current.FullName
    foreach ($match in $resourceTokenRegex.Matches($text)) {
        foreach ($resource in Resolve-ResourceToken $match.Groups[1].Value) {
            Add-UsedResource $resource "resource dependency: $($current.Rel)" $match.Groups[1].Value
        }
    }
    if ($skinNamePattern) {
        foreach ($match in [regex]::Matches($text, $skinNamePattern)) {
            $skinName = $match.Groups[1].Value
            if ($skinByName.ContainsKey($skinName)) {
                foreach ($skinFile in $skinByName[$skinName].ToArray()) {
                    Add-UsedResource $skinFile "resource text contains: $($current.Rel)" $skinName
                }
            }
        }
    }
}

$usedSkin = @($skinFiles | Where-Object { $script:usedResources.ContainsKey($_.Rel) } | Sort-Object Ext, LocalRel)
$unusedSkin = @($skinFiles | Where-Object { !$script:usedResources.ContainsKey($_.Rel) } | Sort-Object Ext, LocalRel)
$byExt = @($skinFiles | Group-Object Ext | Sort-Object Name | ForEach-Object {
    [pscustomobject]@{
        Ext    = $_.Name
        Total  = $_.Count
        Used   = @($_.Group | Where-Object { $script:usedResources.ContainsKey($_.Rel) }).Count
        Unused = @($_.Group | Where-Object { !$script:usedResources.ContainsKey($_.Rel) }).Count
    }
})

$knownNames = @(
    'g1108_saber_head.mesh',
    'g1108_pickaxe_wood_01.mesh',
    'artisan_hammer.mesh',
    'g1008_camouflage_double_blue2_000.skin',
    'g1008_camouflage_double.anim',
    'g1008_props_diamond_2.mesh'
)
$knownRows = foreach ($name in $knownNames) {
    if ($script:resourcesByName.ContainsKey($name)) {
        foreach ($resource in $script:resourcesByName[$name].ToArray()) {
            if ($resource.Kind -eq 'skin') {
                [pscustomobject]@{
                    Name   = $name
                    Rel    = $resource.Rel
                    Used   = $script:usedResources.ContainsKey($resource.Rel)
                    Reason = if ($script:reasons.ContainsKey($resource.Rel)) { ($script:reasons[$resource.Rel] | Select-Object -First 1) } else { '' }
                }
            }
        }
    } else {
        [pscustomobject]@{ Name = $name; Rel = 'NOT_FOUND'; Used = $false; Reason = '' }
    }
}

$reportPath = Join-Path $root 'Task\g1108_res_skin_unused_report.md'
$lines = New-Object System.Collections.Generic.List[string]
$lines.Add('# g1108 res/skin unused candidate report') | Out-Null
$lines.Add('') | Out-Null
$lines.Add('Root: `' + $root + '`') | Out-Null
$lines.Add('') | Out-Null
$lines.Add('## Scope') | Out-Null
$lines.Add('') | Out-Null
$lines.Add('- Only scans references inside this g1108 repository.') | Out-Null
$lines.Add('- `res/resource.cfg` and `res/necessary.json` directory registration is not counted as per-file usage.') | Out-Null
$lines.Add('- Used means: referenced by business text, or reachable through referenced actor/effect/skin resource dependency closure.') | Out-Null
$lines.Add('- This is an unused candidate list, not a delete approval list.') | Out-Null
$lines.Add('') | Out-Null
$lines.Add('## Summary') | Out-Null
$lines.Add('') | Out-Null
$lines.Add("- Business files scanned: $($businessFiles.Count)") | Out-Null
$lines.Add("- res/skin files: $($skinFiles.Count)") | Out-Null
$lines.Add("- Used skin files: $($usedSkin.Count)") | Out-Null
$lines.Add("- Unused candidate skin files: $($unusedSkin.Count)") | Out-Null
$lines.Add("- Used resources in closure (actor/effect/skin): $($script:usedResources.Count)") | Out-Null
$lines.Add('') | Out-Null
$lines.Add('## By Extension') | Out-Null
$lines.Add('') | Out-Null
$lines.Add('| Ext | Total | Used | Unused |') | Out-Null
$lines.Add('| --- | ---: | ---: | ---: |') | Out-Null
foreach ($row in $byExt) {
    $lines.Add("| $($row.Ext) | $($row.Total) | $($row.Used) | $($row.Unused) |") | Out-Null
}
$lines.Add('') | Out-Null
$lines.Add('## Verification Samples') | Out-Null
$lines.Add('') | Out-Null
$lines.Add('| Name | Rel | Used | First reason |') | Out-Null
$lines.Add('| --- | --- | --- | --- |') | Out-Null
foreach ($row in $knownRows) {
    $reason = ($row.Reason -replace '\|', '/')
    $lines.Add("| $($row.Name) | $($row.Rel) | $($row.Used) | $reason |") | Out-Null
}
$lines.Add('') | Out-Null
$lines.Add('## Unused Candidates') | Out-Null
$lines.Add('') | Out-Null
$lines.Add('| Path | Ext |') | Out-Null
$lines.Add('| --- | --- |') | Out-Null
foreach ($file in $unusedSkin) {
    $lines.Add('| `' + $file.LocalRel + '` | ' + $file.Ext + ' |') | Out-Null
}

[IO.File]::WriteAllLines($reportPath, $lines, [Text.Encoding]::UTF8)

Write-Output "REPORT=$reportPath"
Write-Output "BUSINESS_FILES=$($businessFiles.Count)"
Write-Output "SKIN_TOTAL=$($skinFiles.Count) USED_SKIN=$($usedSkin.Count) UNUSED_SKIN=$($unusedSkin.Count) USED_RESOURCES=$($script:usedResources.Count)"
Write-Output 'BY_EXT'
$byExt | Format-Table -AutoSize | Out-String -Width 200
Write-Output 'KNOWN'
$knownRows | Format-Table -AutoSize | Out-String -Width 260
Write-Output 'UNUSED_FIRST_80'
$unusedSkin | Select-Object -First 80 LocalRel, Ext | Format-Table -AutoSize | Out-String -Width 260
