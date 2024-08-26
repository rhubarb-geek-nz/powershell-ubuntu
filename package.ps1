#!/usr/bin/env pwsh
# Copyright (c) 2024 Roger Brown.
# Licensed under the MIT License.

Param($Version = '7.4.5', $Maintainer)

$ReleaseTag = "v$Version"
$ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop
$WorkDir = 'github-PowerShell'
$ProjectName = 'powershell-unix'
$ProjectDir = "src/$ProjectName"
$ProjectFile = "$ProjectDir/$ProjectName.csproj"
$Env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'

trap
{
	throw $PSItem
}

if (-not $Maintainer)
{
	$Maintainer = git config user.email

	if (-not $Maintainer)
	{
		throw "No Maintainer"
	}
}

if (-not ( Test-Path $WorkDir ))
{
	sh -c "git clone https://github.com/PowerShell/PowerShell.git $WorkDir --single-branch --branch $ReleaseTag"

	if ($LastExitCode)
	{
		exit $LastExitCode
	}

	Push-Location $WorkDir

	try
	{
		[xml]$xml = Get-Content $ProjectFile
		$xml.documentElement.SetAttribute('TreatAsLocalProperty','SelfContained')
		$pg = $xml.SelectSingleNode('/Project/PropertyGroup')
		$sc = $xml.CreateElement('SelfContained')
		$tn = $xml.CreateTextNode('False')
		$null = $sc.AppendChild($tn)
		$null = $pg.AppendChild($sc)
		$xml.Save("$PWD/$ProjectFile")
		Import-Module ./build.psm1
		Start-PSBootstrap
		Start-PSBuild -Configuration Release -Clean -ReleaseTag $ReleaseTag
	}
	finally
	{
		Pop-Location
	}
}

$OriginalFile = "powershell_$Version-1.deb_amd64.deb"

if (-not (Test-Path $OriginalFile))
{
	$Uri = "https://github.com/PowerShell/PowerShell/releases/download/$ReleaseTag/$OriginalFile"

	Invoke-WebRequest -Uri $Uri -OutFile $OriginalFile
}

$Architecture = ( sh -c "dpkg --print-architecture" ).Trim()

$Architecture
$Release = '1.ubuntu'

$OutputFile = "powershell_$Version-$Release`_$Architecture.deb"

if (Test-Path $OutputFile)
{
	Remove-Item $OutputFile
}

$ReleaseDir = "$WorkDir/$ProjectDir/bin/Release"

$Null = New-Item 'control',
		'data',
		'data/usr',
		'data/usr/bin',
		'data/opt',
		'data/opt/microsoft',
		'data/opt/microsoft/powershell' -ItemType Directory

Get-ChildItem $ReleaseDir -Directory -Name 'publish' -Recurse | ForEach-Object {
	$SrcDir = Join-Path $ReleaseDir $_
	sh -c "find $SrcDir -type l | xargs --no-run-if-empty rm"
	Copy-Item $SrcDir 'data/opt/microsoft/powershell/7' -Recurse
}

sh -e -c "cd data ; ar p ../$OriginalFile data.tar.gz | tar xvfz - ./usr/local/share/man/man1/pwsh.1.gz"
		
if ($LastExitCode)
{
	exit $LastExitCode
}

$Size = sh -c 'du -sk data | while read A B; do echo $A; done' 

$Maintainer
$Size

@"
Package: powershell
Version: $Version-$Release
License: MIT License
Vendor: Microsoft Corporation
Architecture: $Architecture
Maintainer: $Maintainer
Installed-Size: $Size
Depends: dotnet-runtime-8.0
Section: shells
Priority: optional
Homepage: https://microsoft.com/powershell
Description: PowerShell is an automation and configuration management platform.
 It consists of a cross-platform command-line shell and associated scripting language.
"@ | Set-Content 'control/control'

@'
set -e
case "$1" in
	(configure)
		add-shell /usr/bin/pwsh
		;;
	(*)
		;;
esac
'@ | Set-Content 'control/postinst'

@'
set -e
case "$1" in
	(remove)
		remove-shell /usr/bin/pwsh
		remove-shell /opt/microsoft/powershell/7/pwsh
		;;
	(*)
		;;
esac
'@ | Set-Content 'control/postrm'

'2.0' | Set-Content 'debian-binary'

foreach ($cmd in 'find data -type f | xargs chmod -x',
		'chmod ugo+x data/opt/microsoft/powershell/7/pwsh control/postinst control/postrm',
		'ln -s /opt/microsoft/powershell/7/pwsh data/usr/bin/pwsh',
		'cd data ; find * -type f -print0 | xargs -r0 md5sum > ../control/md5sum',
		'cd data ; tar  --owner=0 --group=0 --create --xz --file ../data.tar.xz ./*',
		'cd control ; tar  --owner=0 --group=0 --create --xz --file ../control.tar.xz ./*',
		"ar r $OutputFile debian-binary control.tar.xz data.tar.xz",
		'rm -rf debian-binary control.tar.xz data.tar.xz data control')
{
	sh -e -c $cmd

	if ($LastExitCode)
	{
		exit $LastExitCode
	}
}
