param([Switch]$isolated,[Switch]$test)
pushd $PSScriptRoot
$ErrorActionPreference = "Stop"

if( $PSVersionTable.PSVersion.Major -lt 6 ) { 
    write-error "This script requires Core PowerShell (don't worry: generated cmdlets can work in Core PowerShell or Windows Powershell)" 
}

if( -not $isolated )  {
    # this ensures that we can run the script repeatedly without worrying about locked files/folders
    write-host -fore green "Spawning in isolated process." 
    $pwsh = [System.Diagnostics.Process]::GetCurrentProcess().Path
    & $pwsh -command $MyInvocation.MyCommand.Path -isolated 

    if($test) {
        $mpath = $(( dir ./*.psd1)[0].fullname)
        $mname = $(( dir ./*.psd1)[0].basename)
        & $pwsh -noexit -command  "function prompt { `$ESC = [char]27 ; Write-Host ('PS ' + `$(get-location) +' ['+ `$ESC +'[46m testing $mname '+ `$ESC +'[0m] >') -nonewline -foregroundcolor cyan ; write-host -fore white -nonewline '' ;  return ' ' }   ; ipmo '$mpath' "
    } else {
        write-host -fore cyan "To test this module in a new powershell process, run `n"
        write-host -fore white " & '$([System.Diagnostics.Process]::GetCurrentProcess().Path)' -noexit -command ipmo '$( (dir ./*.psd1)[0].fullname )' "        
        write-host -fore cyan "`nor use -test with this script`n"
    }
    return
}

write-host -fore green "Cleaning folders..."
@('./exported','./obj', './bin') |% { $shh = rmdir -recurse -ea 0 $_ }

if( test-path ./bin ) {
    write-error "Unable to clean binary folder. (a process may have an open handle.)"
}

write-host -fore green "Compiling private module code"
$shh = dotnet publish --configuration Release --output bin
if( $lastExitCode -ne 0 ) {
    # if it fails, let's do it again so the output comes out nicely.
    dotnet publish --configuration Release --output bin
    write-error "Compilation failed"
}

@('./bin/Debug','./bin/Release') |% { $shh = rmdir -recurse -ea 0 $_ }
$dll = (dir bin\*.private.dll)[0]

if( -not (test-path $dll) ) {
     write-error "Unable to find output assembly."
}

$commands = get-command -module (ipmo $dll -passthru)

write-host -fore gray "Private Module loaded."


if( $commands.length -eq 0  ) {
     write-error "Unable get commands from private module."
}

$outputs = @{}

write-host -fore green "Processing cmdlet variants"
$commands |% {
    
    $metadata  = New-Object System.Management.Automation.CommandMetaData($_)
    if( $metadata.Name.IndexOf("_") -gt -1 ) {
        $targetCmdlet = $metadata.Name.split("_")[0];
        $variant = $metadata.Name.split("_")[1];
    } else {
        $targetCmdlet = $metadata.Name
        $variant = "default"
    }

    if( -not ($outputs.ContainsKey($targetCmdlet))) {
        $newCmdlet = @{ 
             cmdlet = New-Object System.Management.Automation.CommandMetaData($metadata)
             name = $targetCmdlet
             variants = @{}
        }
        # create the new target cmdlet 
        $newCmdlet.cmdlet.Parameters.Clear();
        $outputs[$targetCmdlet] = $newCmdlet;
    }

    $cmdlet = $outputs[$targetCmdlet]
    
    # add the variant
    $gb = [System.Management.Automation.ProxyCommand]::GetBegin( $metadata ) 
    $ct = $metadata.Parameters.Keys.Count
    
    $newCmdlet.variants.add( $variant, @{ method = $gb; pcount = $ct; name = $name} )

    # copy parameters across
    $metadata.Parameters.Keys |% {
        $name = $_;
        $p = $metadata.Parameters[$name]
        if( -not ($cmdlet.cmdlet.parameters.ContainsKey($name) ) ) {
            # add the parameter to the target
            $newParam = New-Object System.Management.Automation.ParameterMetadata($p);
            $newParam.ParameterSets.Clear()
            $newCmdlet.cmdlet.Parameters.add($name, $newParam)
        }
        $param = $newCmdlet.cmdlet.Parameters[$name];
        $param.ParameterSets.Add( $variant, $p.ParameterSets["__AllParameterSets"]);
    }
}

$shh = mkdir "./exported" 

write-host -fore green "Generating unified cmdlet proxies"
# Now, loop thru and spit out the proxies
$outputs.Keys |% {
    $cmdletname= $_
    $each = $outputs[$cmdletname]
    $cmd = [System.Management.Automation.ProxyCommand]::create($each.cmdlet)

    if( $each.variants.Count -eq 1 ) {
        $text = $cmd
    } else {
        $b = [System.Management.Automation.ProxyCommand]::GetBegin($each.cmdlet)
    
        $newBegin = "`n"
        $newBegin = $newBegin + '  switch ($PsCmdlet.ParameterSetName) { ';
        $newBegin = $newBegin + "`n"
        $pc = 100

        $each.variants.Keys |% {
            $name = $_;

            if ( $each.variants[$name].pcount -lt $pc ) {
                # write-host "$name => $pc $($each.variants[$name].pcount)"
                $pc = $each.variants[$name].pcount
                $defaultImpl = $each.variants[$name].method
                $defaultName = $name
            }
            
            $variant = $each.variants[$name].method;
            $t =  "`n  '$_' {`n"
            $t = $t + $variant
            $t = $t + "`n}`n"
            $newBegin = $newBegin  + $t;
        }

        # add a default case (choose the first?)
        $t =  "`n  default {`n"
        $t = $t + $defaultImpl
        $t = $t + "`n}`n"
        $newBegin = $newBegin  + $t;

        $newBegin = $newBegin + "`n}`n";
            
        $text = $cmd.replace( $b, $newBegin ) 
        $text = $text.replace( "[CmdletBinding()]", "[CmdletBinding(DefaultParameterSetName='$defaultName')]")
    }
    $text = "function ${cmdletname} {`n$text`n}`n"
    set-content "exported/${cmdletname}.ps1" -value $text
}
  
  popd
write-host -fore green "Done."
write-host -fore green "-------------------------------"

