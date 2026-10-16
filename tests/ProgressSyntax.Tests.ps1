$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$files=@('Backup.Core.psm1','Backup.Windows.psm1','Start-Backup.ps1')
foreach($name in $files) {
 $path=Join-Path (Join-Path $root 'package') $name
 $tokens=$null;$errors=$null
 [void][Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
 if($errors.Count){$errors|Out-String|Write-Host;throw "Parser failure: $name"}
 $issues=@(Invoke-ScriptAnalyzer -Path $path -Settings @{IncludeRules=@('PSUseCompatibleSyntax');Rules=@{PSUseCompatibleSyntax=@{Enable=$true;TargetVersions=@('5.1')}}})
 if($issues.Count){$issues|Format-List|Out-String|Write-Host;throw "PS5.1 compatibility failure: $name"}
 Write-Host "PASS: parser + PSUseCompatibleSyntax target5.1: $name"
}
