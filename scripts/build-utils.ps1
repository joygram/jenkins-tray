#
#   Script origin: https://github.com/dotnet/roslyn/tree/master/build/scripts
#
# Collection of powershell build utility functions that we use across our scripts.

Set-StrictMode -version 2.0
$ErrorActionPreference="Stop"

# Declare a number of useful variables for other scripts to use
[string]$repoDir = Resolve-Path (Join-Path $PSScriptRoot "..")
[string]$binariesDir = Join-Path $repoDir "Binaries"

# Handy function for executing a command in powershell and throwing if it 
# fails.  
#
# Use this when the full command is known at script authoring time and 
# doesn't require any dynamic argument build up.  Example:
#
#   Exec-Block { & $msbuild Test.proj }
# 
# Original sample came from: http://jameskovacs.com/2010/02/25/the-exec-problem/
function Exec-Block([scriptblock]$cmd) {
    & $cmd

    # Need to check both of these cases for errors as they represent different items
    # - $?: did the powershell script block throw an error
    # - $lastexitcode: did a windows command executed by the script block end in error
    if ((-not $?) -or ($lastexitcode -ne 0)) {
        throw "Command failed to execute: $cmd"
    } 
}

# Handy function for executing a windows command which needs to go through 
# windows command line parsing.  
#
# Use this when the command arguments are stored in a variable.  Particularly 
# when the variable needs reparsing by the windows command line. Example:
#
#   $args = "/p:ManualBuild=true Test.proj"
#   Exec-Command $msbuild $args
# 
function Exec-Command([string]$command, [string]$commandArgs, [switch]$forwardExitCode) {
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $command
    $startInfo.Arguments = $commandArgs

    $startInfo.RedirectStandardOutput = $true
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.WorkingDirectory = Get-Location

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    $process.StartInfo.RedirectStandardOutput = $true;
    $process.Start() | Out-Null

    $finished = $false
    try {
        # The OutputDataReceived event doesn't fire as events are sent by the 
        # process in powershell.  Possibly due to subtlties of how Powershell
        # manages the thread pool that I'm not aware of.  Using blocking
        # reading here as an alternative which is fine since this blocks 
        # on completion already.
        $out = $process.StandardOutput
        while (-not $out.EndOfStream) {
            $line = $out.ReadLine()
            Write-Output $line
        }

        while (-not $process.WaitForExit(100)) { 
            # Non-blocking loop done to allow ctr-c interrupts
        }

        $finished = $true
        if (!$forwardExitCode.IsPresent) {
            if ($process.ExitCode -ne 0) { 
                throw "Command failed to execute: $command $commandArgs" 
            }
        }
    }
    finally {
        # If we didn't finish then an error occured or the user hit ctrl-c.  Either
        # way kill the process
        if (-not $finished) {
            $process.Kill()
        }
    }
    if ($forwardExitCode.IsPresent) {
        return $process.ExitCode
    }
}

# Refer to Exec-Command above
#
# Returns stdout, stderr and exit code as an array.
function Exec-Command2([string]$command, [string]$commandArgs) {
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $command
    $startInfo.Arguments = $commandArgs

    $startInfo.RedirectStandardOutput = $true
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.WorkingDirectory = Get-Location

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    $process.StartInfo.RedirectStandardOutput = $true;
    $process.StartInfo.RedirectStandardError = $true;
    $process.Start() | Out-Null

    $finished = $false
    $stdout = [string]::Empty
    $stderr = [string]::Empty
    $exitCode = -1
    try {
        # The OutputDataReceived event doesn't fire as events are sent by the 
        # process in powershell.  Possibly due to subtlties of how Powershell
        # manages the thread pool that I'm not aware of.  Using blocking
        # reading here as an alternative which is fine since this blocks 
        # on completion already.
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        while (-not $process.WaitForExit(100)) { 
            # Non-blocking loop done to allow ctr-c interrupts
        }

        $finished = $true
        $exitCode = $process.ExitCode
    }
    catch {
        Write-Host "$($_.Exception.Message)"
        $exitCode = -1
    }
    finally {
        # If we didn't finish then an error occured or the user hit ctrl-c.  Either
        # way kill the process
        if (-not $finished) {
            $process.Kill()
            $exitCode = -1
        }
    }
    return $stdout, $stderr, $exitCode
}

# Handy function for executing a powershell script in a clean environment with 
# arguments.  Prefer this over & sourcing a script as it will both use a clean
# environment and do proper error checking
function Exec-Script([string]$script, [string]$scriptArgs = "") {
    Exec-Command "powershell" "-noprofile -executionPolicy RemoteSigned -file `"$script`" $scriptArgs"
}

# Ensure that GitVersion is installed and return the path to
# the executable to use.
function Ensure-GitVersion () {
    $nuget = Ensure-NuGet
    $gitversionFolder = Ensure-BasicTool "GitVersion.CommandLine"
    $gitversion = Get-ChildItem -Path $gitversionFolder -Recurse -Filter GitVersion.exe | Select -First 1
    if (Test-Path $gitversion.FullName -PathType Leaf) {
        $json = Join-Path -Path (Split-Path -Path $nuget) -ChildPath "version.json"
        Exec-Command $gitversion.FullName -commandArgs "/updateassemblyinfo" | Out-File $json -Encoding ASCII -Force
    }
    return $gitversion
}

# Ensure that NuGet is installed and return the path to the 
# executable to use.
function Ensure-NuGet() {
    Exec-Block { & (Join-Path $PSScriptRoot "download-nuget.ps1") } | Out-Host
    $nuget = Join-Path $repoDir "NuGet.exe"
    return $nuget
}

# Ensure a basic tool used for building our Repo is installed and 
# return the path to it.
function Ensure-BasicTool([string]$name, [string]$version) {
    if ([string]::IsNullOrEmpty($version)) {
        $p = Join-Path (Get-PackagesDir) "$($name)"
    } else {
        $p = Join-Path (Get-PackagesDir) "$($name).$($version)"
    }
    if (-not (Test-Path $p)) {
        $nuget = Ensure-NuGet

        if ([string]::IsNullOrEmpty($version)) {
            Exec-Block { & $nuget install $name -OutputDirectory (Get-PackagesDir) } | Out-Host
        } else {
            Exec-Block { & $nuget install $name -OutputDirectory (Get-PackagesDir) -Version $version } | Out-Null
        }
    }
    
    return $p
}

# Ensure that MSBuild is installed and return the path to the
# executable to use.
function Ensure-MSBuild([switch]$xcopy = $false) {
    $both = Get-MSBuildKindAndDir -xcopy:$xcopy
    $msbuildDir = $both[1]
    switch ($both[0]) {
        "xcopy" { break; }
        "vscmd" { break; }
        "vsinstall" { break; }
        default {
            throw "Unknown MSBuild installation type $($both[0])"
        }
    }

    $p = Join-Path $msbuildDir "msbuild.exe"
    return $p
}

function Create-Directory([string]$dir) {
    New-Item $dir -ItemType Directory -ErrorAction SilentlyContinue | Out-Null
}

# Return the version of the NuGet package as used in this repo
function Get-PackageVersion([string]$name) {
    $name = $name.Replace(".", "")
    $deps = Join-Path $repoDir "build\Targets\Packages.props"
    $nodeName = "$($name)Version"
    $x = [xml](Get-Content -raw $deps)
    $node = $x.Project.PropertyGroup[$nodeName]
    if ($node -eq $null) { 
        throw "Cannot find package $name in Packages.props"
    }

    return $node.InnerText
}

# Locate the directory where our NuGet packages will be deployed.  Needs to be kept in sync
# with the logic in Version.props
function Get-PackagesDir() {
    $d = $null
    if ($env:NUGET_PACKAGES -ne $null) {
        $d = $env:NUGET_PACKAGES
    }
    else {
        $d = Join-Path $env:UserProfile ".nuget\packages\"
    }

    Create-Directory $d
    return $d
}

# Locate the directory of a specific NuGet package which is restored via our main 
# toolset values.
function Get-PackageDir([string]$name, [string]$version = "") {
    if ($version -eq "") {
        $version = Get-PackageVersion $name
    }

    $p = Get-PackagesDir
    $p = Join-Path $p $name
    $p = Join-Path $p $version
    return $p
}

# The intent of this script is to locate and return the path to the MSBuild directory that
# we should use for bulid operations.  The preference order for MSBuild to use is as 
# follows
#
#   1. MSBuild from an active VS command prompt
#   2. MSBuild from a machine wide VS install
#   3. MSBuild from the xcopy toolset 
#
# This function will return two values: the kind of MSBuild chosen and the MSBuild directory.
function Get-MSBuildKindAndDir([switch]$xcopy = $false) {

    if ($xcopy) { 
        Write-Output "xcopy"
        Write-Output (Get-MSBuildDirXCopy)
        return
    }

    # MSBuild from an active VS command prompt.  
    if (${env:VSINSTALLDIR} -ne $null) {

        # This line deliberately avoids using -ErrorAction.  Inside a VS command prompt
        # an MSBuild command should always be available.
        $command = (Get-Command msbuild -ErrorAction SilentlyContinue)
        if ($command -ne $null) {
            $p = Split-Path -parent $command.Path
            Write-Output "vscmd"
            Write-Output $p
            return
        }
    }

    # Look for a valid VS installation
    try {
        $p = Get-VisualStudioDir
        $p = Join-Path $p "MSBuild\15.0\Bin"
        Write-Output "vsinstall"
        Write-Output $p
        return
    }
    catch { 
        # Failures are expected here when no VS installation is present on the 
        # machine.
    }

    Write-Output "xcopy"
    Write-Output (Get-MSBuildDirXCopy)
    return
}

# Locate the xcopy version of MSBuild
function Get-MSBuildDirXCopy() {
    $version = "0.2.0-alpha"
    $name = "RoslynTools.MSBuild"
    $p = Ensure-BasicTool $name $version
    $p = Join-Path $p "tools\msbuild"
    return $p
}

function Get-MSBuildDir([switch]$xcopy = $false) {
    $both = Get-MSBuildKindAndDir -xcopy:$xcopy
    return $both[1]
}

# Get the directory of the first Visual Studio which meets our minimal 
# requirements for the Roslyn repo
function Get-VisualStudioDir() {
    $vswhere = Join-Path (Ensure-BasicTool "vswhere" "1.0.50") "tools\vswhere.exe"
    $output = & $vswhere -requires Microsoft.Component.MSBuild -format json | Out-String
    if (-not $?) {
        throw "Could not locate a valid Visual Studio"
    }

    $j = ConvertFrom-Json $output
    $p = $j[0].installationPath
    return $p
}

# Clear out the NuGet package cache
function Clear-PackageCache() {
    $nuget = Ensure-NuGet
    Exec-Block { & $nuget locals all -clear } | Out-Host
}

# Restore a single project
function Restore-Project([string]$fileName, [string]$nuget, [string]$msbuildDir) {
    $nugetConfig = Join-Path $repoDir "nuget.config"

    $filePath = $fileName
    if (-not (Test-Path $filePath)) {
        $filePath = Join-Path $repoDir $fileName
    }

    Exec-Block { & $nuget restore -verbosity quiet -configfile $nugetConfig -MSBuildPath $msbuildDir -Project2ProjectTimeOut 1200 $filePath } | Write-Host
}

# Restore all of the projects that the repo consumes
function Restore-Packages([string]$msbuildDir = "", [string]$project = "") {
    $nuget = Ensure-NuGet
    if ($msbuildDir -eq "") {
        $msbuildDir = Get-MSBuildDir
    }

    Write-Host "Restore using MSBuild at $msbuildDir"

    if ($project -ne "") {
        Write-Host "Restoring project $project"
        Restore-Project -fileName $project -msbuildDir $msbuildDir -nuget $nuget
    }
    else {
        $all = @(
            "JenkinsTray:JenkinsTray.sln"
            )

        foreach ($cur in $all) {
            $both = $cur.Split(':')
            Write-Host "Restoring $($both[0])"
            Restore-Project -fileName $both[1] -msbuildDir $msbuildDir -nuget $nuget
        }
    }
}

# Restore all of the projects that the repo consumes
function Restore-All([string]$msbuildDir = "") {
    Restore-Packages -msbuildDir $msbuildDir
}
