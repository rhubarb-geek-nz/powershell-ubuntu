#!/usr/bin/env pwsh
# Copyright (c) 2024 Roger Brown.
# Licensed under the MIT License.

Param(
	$Version,
	$Maintainer,
	$Release = '1.ubuntu'
)

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

if ($Version)
{
	$ReleaseTag = "v$Version"
}
else
{
	$ReleaseTag = (Invoke-RestMethod -Uri 'https://api.github.com/repos/PowerShell/PowerShell/releases/latest').tag_name
	$Version = $ReleaseTag.Substring(1)
}

$ReleaseTag

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

		foreach ($Arch in 'arm', 'arm64', 'x64')
		{
			Start-PSBuild -Configuration Release -ReleaseTag $ReleaseTag -Runtime "linux-$Arch"
		}
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

$ReleaseDir = "$WorkDir/$ProjectDir/bin/Release"

Get-ChildItem $ReleaseDir -Name 'publish' -Directory -Recurse | ForEach-Object {
	$Configuration = $_

	$ConfigurationElements = $Configuration.Split('/')

	if ($ConfigurationElements.Length -eq 3)
	{
		$DotnetRuntime = $ConfigurationElements[0].Replace('net','dotnet-runtime-')

		$Architecture = $ConfigurationElements[1].Split('-')[-1]

		$ArchMap = @{
			'arm' = 'armhf'
			'arm64' = 'arm64'
			'x64' = 'amd64'
		}

		$Architecture = $ArchMap.$Architecture

		$OutputFile = "powershell_$Version-$Release`_$Architecture.deb"

		if (Test-Path $OutputFile)
		{
			Remove-Item $OutputFile
		}

		$Null = New-Item 'control',
			'data',
			'data/usr',
			'data/usr/bin',
			'data/opt',
			'data/opt/microsoft',
			'data/opt/microsoft/powershell' -ItemType Directory

		$SrcDir = Join-Path $ReleaseDir $Configuration
		sh -c "find $SrcDir -type l | xargs --no-run-if-empty rm"
		Copy-Item $SrcDir 'data/opt/microsoft/powershell/7' -Recurse

		sh -e -c "cd data ; ar p ../$OriginalFile data.tar.gz | tar xfz - ./usr/local/share/man/man1/pwsh.1.gz ./usr/share/doc/powershell/changelog.gz"

		if ($LastExitCode)
		{
			exit $LastExitCode
		}

		$Size = sh -c 'du -sk data | while read A B; do echo $A; done'

@"
Package: powershell
Version: $Version-$Release
License: MIT License
Vendor: Microsoft Corporation
Architecture: $Architecture
Maintainer: $Maintainer
Installed-Size: $Size
Depends: $DotnetRuntime
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
	}
}
