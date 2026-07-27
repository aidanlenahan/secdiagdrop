<#
.SYNOPSIS
    Workstation maintenance + safeguarding audit. Built to run from a URL, in
    memory, leaving nothing behind.

.HOW IT IS MEANT TO RUN
    From your launcher (shortcut / Run box), one line, nothing saved to disk:

        powershell -NoProfile -ExecutionPolicy Bypass -Command "& ([scriptblock]::Create((irm 'https://YOUR-SCRIPT-URL'))) -Token 'YOUR_DROP_TOKEN' -Computer '101' -Location 'Room A'"

    The script never writes itself to disk, never writes the diagnostic to disk
    (it uploads to your Drive only), and securely wipes every temp artifact on
    exit. A SQLite tool is fetched ONLY if you approve a deletion.

.SAFEGUARDING
    Inappropriate content (adult / gambling) is recorded in the diagnostic and
    reported to your overseers via the upload. Deletion of that content is
    BLOCKED unless the diagnostic uploaded successfully first, so nothing is
    removed before it is preserved. If you ever see material involving a MINOR,
    do NOT delete it - preserve it and contact law enforcement / your lead.

    Saved logins are flagged by DOMAIN only. Passwords are never decrypted,
    read, or displayed.
#>

#Requires -Version 5.1
[CmdletBinding()]
param(
    [string] $Token,
    [string] $Computer,
    [string] $Location,
    [string] $Description,
    [string] $Problems,
    [string] $Technician = $env:USERNAME,
    [ValidateRange(1,99)] [int] $DiskWarnPercent = 50,
    [int]    $LargeFileMB = 250,
    [int]    $StaleDays   = 90,
    [string] $LocalFallbackPath,     # used ONLY if upload fails and you opt in
    [switch] $SkipUpdates,
    [switch] $SkipBrowser,
    [switch] $NonInteractive
)

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

# ============================================================================
#  CONFIG  - bake your endpoints in when you host the script; keep the TOKEN
#  out of the hosted copy and pass it with -Token instead.
# ============================================================================
$Config = @{
    UploadEndpoint = 'https://script.google.com/macros/s/DEPLOY_ID/exec'
    UploadToken    = $Token                       # from -Token, not hard-coded
    SqliteToolUrl  = 'https://raw.githubusercontent.com/YOU/REPO/main/sqlite3.exe'

    ApprovalMode   = 'Ntfy'                        # 'None' | 'AppsScript' | 'Ntfy'
    NtfyServer     = 'https://ntfy.sh'
    NtfyTopic      = 'CHANGE-ME-to-something-unguessable'
    ApprovalTimeoutSec = 180

    Organization   = 'Field Maintenance'
}

$script:Findings  = New-Object System.Collections.Generic.List[object]
$script:Actions   = New-Object System.Collections.Generic.List[object]
$script:Safeguard = New-Object System.Collections.Generic.List[object]
$script:StartTime = Get-Date
$script:Intake    = $null
$script:Uploaded  = $false
$script:Sqlite3   = $null
$script:Work      = Join-Path $env:TEMP ('.mnt_' + [guid]::NewGuid().ToString('N').Substring(0,10))
New-Item -ItemType Directory -Path $script:Work -Force | Out-Null
try { [Console]::OutputEncoding=[Text.Encoding]::UTF8; $OutputEncoding=[Text.Encoding]::UTF8 } catch {}

# ============================================================================
#region  SECURE TEMP HANDLING
# ============================================================================
function Remove-Secure { param($Path)
    try{ if(Test-Path $Path -PathType Leaf){
        $len=(Get-Item $Path).Length
        if($len -gt 0){ $fs=[IO.File]::OpenWrite($Path); $b=New-Object byte[] 65536; (New-Object Random).NextBytes($b)
            $w=0; while($w -lt $len){ $n=[math]::Min(65536,$len-$w); $fs.Write($b,0,$n); $w+=$n }; $fs.Flush(); $fs.Close() }
        Remove-Item $Path -Force -EA SilentlyContinue } }catch{} }
function New-TempCopy { param($Src)
    $dst=Join-Path $script:Work ([guid]::NewGuid().ToString('N')+'.tmp')
    Copy-Item $Src $dst -Force -EA Stop; $dst }
function Clear-Workspace {
    try{ Get-ChildItem $script:Work -File -Recurse -Force -EA SilentlyContinue|ForEach-Object{ Remove-Secure $_.FullName }
         Remove-Item $script:Work -Recurse -Force -EA SilentlyContinue }catch{}
    foreach($v in 'Token'){ try{ Set-Variable -Name $v -Value $null -Scope Script -EA SilentlyContinue }catch{} }
    $Config.UploadToken=$null
    [GC]::Collect() }
#endregion

# ============================================================================
#region  TERMINAL UI  (same look as before)
# ============================================================================
$UI=@{W=78;Accent='Cyan';Dim='DarkGray';Ok='Green';Warn='Yellow';Crit='Red';Info='Gray';Head='White'}
$G=@{TL='┌';TR='┐';BL='└';BR='┘';H='─';V='│';LT='├';RT='┤';DTL='╔';DTR='╗';DBL='╚';DBR='╝';DH='═';DV='║';Full='█';Light='░';Ok='✔';Warn='▲';Crit='✖';Info='•';Arrow='→'}
function LColor{param($L)switch($L){'Ok'{$UI.Ok}'Warn'{$UI.Warn}'Critical'{$UI.Crit}'Head'{$UI.Head}default{$UI.Info}}}
function LGlyph{param($L)switch($L){'Ok'{$G.Ok}'Warn'{$G.Warn}'Critical'{$G.Crit}default{$G.Info}}}
function Clip{param($t,$m)if($null-eq$t){return''}; $t=$t-replace'[\r\n\t]',' '; if($t.Length-le$m){return $t}; if($m-le3){return $t.Substring(0,$m)}; $t.Substring(0,$m-3)+'...'}
function Banner{param($Title,$Sub='',$Color=$UI.Accent)$i=$UI.W-2;Write-Host ''
    Write-Host ($G.DTL+($G.DH*$i)+$G.DTR) -ForegroundColor $Color
    $p=[math]::Max(0,[int](($i-$Title.Length)/2));Write-Host ($G.DV+(' '*$p)+$Title+(' '*($i-$p-$Title.Length))+$G.DV) -ForegroundColor $Color
    if($Sub){$p2=[math]::Max(0,[int](($i-$Sub.Length)/2));Write-Host ($G.DV+(' '*$p2)+$Sub+(' '*($i-$p2-$Sub.Length))+$G.DV) -ForegroundColor $UI.Dim}
    Write-Host ($G.DBL+($G.DH*$i)+$G.DBR) -ForegroundColor $Color}
$script:SecNo=0
function Open-Sec{param($T)$script:SecNo++;$l=' {0:00}  {1} '-f$script:SecNo,$T.ToUpper();Write-Host ''
    Write-Host ($G.TL+$G.H+$l+($G.H*[math]::Max(0,$UI.W-3-$l.Length))+$G.TR) -ForegroundColor $UI.Accent}
function Close-Sec{Write-Host ($G.BL+($G.H*($UI.W-2))+$G.BR) -ForegroundColor $UI.Accent}
function Line{param($T='',$L='Info',$In=0)$b=Clip ((' '*$In)+$T) ($UI.W-4)
    Write-Host ($G.V+' ') -NoNewline -ForegroundColor $UI.Accent
    Write-Host ($b.PadRight($UI.W-4)) -NoNewline -ForegroundColor (LColor $L)
    Write-Host (' '+$G.V) -ForegroundColor $UI.Accent}
function Stat{param($T,$L='Info',$In=0)Line ((' '*$In)+(LGlyph $L)+' '+$T) $L}
function KV{param($K,$V,$L='Info')$kw=22;$k=(Clip $K $kw).PadRight($kw);$v=Clip $V ($UI.W-6-$kw)
    Write-Host ($G.V+' ') -NoNewline -ForegroundColor $UI.Accent
    Write-Host $k -NoNewline -ForegroundColor $UI.Dim
    Write-Host $v.PadRight($UI.W-4-$kw) -NoNewline -ForegroundColor (LColor $L)
    Write-Host (' '+$G.V) -ForegroundColor $UI.Accent}
function Div{Write-Host ($G.LT+($G.H*($UI.W-2))+$G.RT) -ForegroundColor $UI.Accent}
function Gauge{param($Label,$Pct,$Detail='',$L='Info')$bw=30;$f=[math]::Min($bw,[math]::Max(0,[int][math]::Round($bw*($Pct/100))));$c=LColor $L;$lb=(Clip $Label 10).PadRight(10)
    Write-Host ($G.V+' ') -NoNewline -ForegroundColor $UI.Accent
    Write-Host $lb -NoNewline -ForegroundColor $UI.Head
    Write-Host ($G.Full*$f) -NoNewline -ForegroundColor $c
    Write-Host ($G.Light*($bw-$f)) -NoNewline -ForegroundColor $UI.Dim
    $t=Clip (' {0,5:N1}%  {1}'-f$Pct,$Detail) ($UI.W-4-10-$bw)
    Write-Host $t.PadRight($UI.W-4-10-$bw) -NoNewline -ForegroundColor $c
    Write-Host (' '+$G.V) -ForegroundColor $UI.Accent}
function Grid{param($Rows,$Cols,$W,$LevelProp)if(-not $Rows){return};$avail=$UI.W-4;$sum=($W|Measure-Object -Sum).Sum+($Cols.Count-1);if($sum-gt$avail){$W[-1]-=($sum-$avail)}
    $h='';for($i=0;$i-lt$Cols.Count;$i++){$h+=(Clip $Cols[$i] $W[$i]).PadRight($W[$i])+' '};Line $h.TrimEnd() 'Head';Line (($G.H)*($UI.W-4)) 'Dim'
    foreach($r in $Rows){$ln='';for($i=0;$i-lt$Cols.Count;$i++){$ln+=(Clip ([string]$r.($Cols[$i])) $W[$i]).PadRight($W[$i])+' '};$lv=if($LevelProp -and $r.$LevelProp){$r.$LevelProp}else{'Info'};Line $ln.TrimEnd() $lv}}
function Spin{param($T)Write-Host ($G.V+'  ') -NoNewline -ForegroundColor $UI.Accent;Write-Host ("$($G.Arrow) $T") -ForegroundColor $UI.Dim}
function Add-Finding{param($Category,[ValidateSet('Ok','Info','Warn','Critical')]$Severity,$Item,$Detail,$Recommendation='')$script:Findings.Add([pscustomobject]@{Category=$Category;Severity=$Severity;Item=$Item;Detail=$Detail;Recommendation=$Recommendation})}
function Add-Safeguard{param($Type,$Severity,$Subject,$Detail)$script:Safeguard.Add([pscustomobject]@{Time=(Get-Date);Type=$Type;Severity=$Severity;Subject=$Subject;Detail=$Detail})}
function Add-Action{param($Category,$Severity,$Summary,$Detail='',$Context,[scriptblock]$Do,[switch]$NeedsUpload)$script:Actions.Add([pscustomobject]@{Id=$script:Actions.Count+1;Category=$Category;Severity=$Severity;Summary=$Summary;Detail=$Detail;Ctx=$Context;Do=$Do;NeedsUpload=[bool]$NeedsUpload})}
function Test-IsAdmin{$id=[Security.Principal.WindowsIdentity]::GetCurrent();(New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)}
function FSize{param($b)if($b-ge1TB){'{0:N2} TB'-f($b/1TB)}elseif($b-ge1GB){'{0:N2} GB'-f($b/1GB)}elseif($b-ge1MB){'{0:N2} MB'-f($b/1MB)}elseif($b-ge1KB){'{0:N2} KB'-f($b/1KB)}else{'{0} B'-f[int]$b}}
function Ask{param($Q,[switch]$DefaultYes)if($NonInteractive){return $false};$s=if($DefaultYes){'[Y/n]'}else{'[y/N]'}
    while($true){Write-Host ("  $($G.Arrow) $Q $s ") -NoNewline -ForegroundColor $UI.Accent;$a=Read-Host
        if([string]::IsNullOrWhiteSpace($a)){return [bool]$DefaultYes};switch -Regex ($a.Trim()){'^(y|yes)$'{return $true}'^(n|no)$'{return $false}default{Write-Host '     y or n.' -ForegroundColor $UI.Warn}}}}
#endregion

# ============================================================================
#region  ON-DEMAND SQLITE3.EXE  (fetched only when a deletion is approved)
# ============================================================================
function Get-Sqlite3 {
    if($script:Sqlite3 -and (Test-Path $script:Sqlite3)){return $script:Sqlite3}
    if(-not $Config.SqliteToolUrl -or $Config.SqliteToolUrl -match 'YOU/REPO'){Stat 'SqliteToolUrl not configured - cannot delete. Skipped.' 'Warn'; return $null}
    try{ [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
        $exe=Join-Path $script:Work 'q.exe'
        Invoke-WebRequest $Config.SqliteToolUrl -OutFile $exe -UseBasicParsing -EA Stop
        $script:Sqlite3=$exe; return $exe }catch{ Stat "Could not fetch SQLite tool: $($_.Exception.Message)" 'Warn'; return $null }
}
function Invoke-Sqlite3 { param($Db,$Sql)
    $exe=Get-Sqlite3; if(-not $exe){throw 'sqlite3 unavailable'}
    $out=& $exe $Db $Sql 2>&1
    if($LASTEXITCODE -ne 0){throw ($out -join ' ')}
    $out
}
#endregion

# ============================================================================
#region  INTAKE
# ============================================================================
function Get-Intake {
    Banner 'WORKSTATION MAINTENANCE + SAFEGUARDING AUDIT' $Config.Organization
    Write-Host ''
    Write-Host ('  '+$G.Warn+' If you ever see material involving a MINOR: do NOT delete it.') -ForegroundColor $UI.Warn
    Write-Host '    Preserve it and contact law enforcement / your safeguarding lead.' -ForegroundColor $UI.Warn
    Open-Sec 'Intake'
    function RF{param($P,$Preset,[switch]$Req)if($Preset){KV $P $Preset 'Ok';return $Preset}
        if($NonInteractive){return '(not supplied)'}
        do{Write-Host ($G.V+'  ') -NoNewline -ForegroundColor $UI.Accent;Write-Host ("{0,-24}: "-f$P) -NoNewline -ForegroundColor $UI.Head;$v=Read-Host}while($Req -and [string]::IsNullOrWhiteSpace($v))
        if([string]::IsNullOrWhiteSpace($v)){'(none reported)'}else{$v.Trim()}}
    $num=RF 'Computer number' $Computer -Req
    $loc=RF 'Computer location' $Location -Req
    $desc=RF 'Computer description' $Description
    Line; Line 'Ongoing problems - one per line, blank to finish:' 'Dim'
    $probs=@()
    if($Problems){$probs=$Problems -split '[;\r\n]+'|Where-Object{$_.Trim()};foreach($p in $probs){Line ('  - '+$p) 'Warn'}}
    elseif(-not $NonInteractive){while($true){Write-Host ($G.V+'    - ') -NoNewline -ForegroundColor $UI.Accent;$p=Read-Host;if([string]::IsNullOrWhiteSpace($p)){break};$probs+=$p.Trim()}}
    if(-not $probs){$probs=@('(none reported)')}
    Close-Sec
    $script:Intake=[pscustomobject]@{ComputerNumber=$num;Location=$loc;Description=$desc;Problems=$probs;Technician=$Technician;Hostname=$env:COMPUTERNAME;User="$env:USERDOMAIN\$env:USERNAME";Timestamp=(Get-Date)}
    $script:Intake
}
#endregion

# ============================================================================
#region  FLAG LISTS
# ============================================================================
$SuspiciousApps=@(
    @{P='*Advanced SystemCare*';C='PUP';S='Warn';R='Fake optimizer nagware'}
    @{P='*Driver Booster*';C='PUP';S='Warn';R='Driver updater, wrong drivers'}
    @{P='*DriverPack*';C='PUP';S='Critical';R='Bundleware installer'}
    @{P='*Reimage*';C='PUP';S='Critical';R='Scareware repair tool'}
    @{P='*Restoro*';C='PUP';S='Critical';R='Scareware repair tool'}
    @{P='*Outbyte*';C='PUP';S='Critical';R='Scareware'}
    @{P='*MyCleanPC*';C='PUP';S='Critical';R='Scareware'}
    @{P='*MacKeeper*';C='PUP';S='Critical';R='Scareware'}
    @{P='*IObit*';C='PUP';S='Warn';R='Bundles other products'}
    @{P='*RegClean*';C='PUP';S='Critical';R='Registry scareware'}
    @{P='*CCleaner*';C='PUP';S='Info';R='Bundles offers, verify'}
    @{P='*Segurazo*';C='PUP';S='Critical';R='Rogue antivirus'}
    @{P='*Total AV*';C='PUP';S='Warn';R='Aggressive affiliate AV'}
    @{P='*Web Companion*';C='PUP';S='Critical';R='Browser hijacker'}
    @{P='*Wajam*';C='PUP';S='Critical';R='Ad injector w/ root cert'}
    @{P='*Superfish*';C='PUP';S='Critical';R='TLS-intercepting adware'}
    @{P='*Toolbar*';C='Toolbar';S='Warn';R='Browser toolbar'}
    @{P='*Ask.com*';C='Toolbar';S='Critical';R='Search hijacker'}
    @{P='*Conduit*';C='Toolbar';S='Critical';R='Search hijacker'}
    @{P='*MyWebSearch*';C='Toolbar';S='Critical';R='Search hijacker'}
    @{P='*Search Protect*';C='Toolbar';S='Critical';R='Blocks settings'}
    @{P='*TeamViewer*';C='RemoteTool';S='Warn';R='Verify intentional'}
    @{P='*AnyDesk*';C='RemoteTool';S='Warn';R='Verify intentional'}
    @{P='*UltraViewer*';C='RemoteTool';S='Critical';R='Scam tool'}
    @{P='*Ammyy*';C='RemoteTool';S='Critical';R='Scam contexts'}
    @{P='*DWAgent*';C='RemoteTool';S='Critical';R='Dropped by scammers'}
    @{P='*RustDesk*';C='RemoteTool';S='Warn';R='Used in scams'}
    @{P='*ScreenConnect*';C='RemoteTool';S='Warn';R='Verify your MSP'}
    @{P='*VNC*';C='RemoteTool';S='Warn';R='VNC server, verify'}
    @{P='*uTorrent*';C='P2P';S='Warn';R='Bundles adware'}
    @{P='*BitTorrent*';C='P2P';S='Warn';R='Policy risk'}
    @{P='*LimeWire*';C='P2P';S='Critical';R='Legacy malware vector'}
    @{P='*KMSPico*';C='Crack';S='Critical';R='License bypass, trojanized'}
    @{P='*KMSAuto*';C='Crack';S='Critical';R='License bypass, trojanized'}
    @{P='*keygen*';C='Crack';S='Critical';R='Key generator'}
    @{P='*XMRig*';C='Miner';S='Critical';R='Monero miner payload'}
    @{P='*NiceHash*';C='Miner';S='Warn';R='Mining power/thermal'}
    @{P='*Norton Crypto*';C='Miner';S='Critical';R='Bundled miner'}
    @{P='Adobe Flash*';C='Legacy';S='Critical';R='Dead since 2020'}
    @{P='QuickTime*';C='Legacy';S='Critical';R='EOL on Windows'}
    @{P='Java*6*';C='Legacy';S='Critical';R='Ancient, unpatched'}
    @{P='Java*7*';C='Legacy';S='Critical';R='Ancient, unpatched'}
    @{P='*McAfee*';C='Bloat';S='Warn';R='OEM trial, check state'}
    @{P='*Norton*';C='Bloat';S='Warn';R='OEM trial, check state'}
    @{P='*Candy Crush*';C='Bloat';S='Info';R='Preinstalled game'}
)
function Test-Suspicious{param($Name,$Publisher='')$o=@();foreach($r in $SuspiciousApps){if($Name -like $r.P -or ($Publisher -and $Publisher -like $r.P)){$o+=[pscustomobject]@{Category=$r.C;Severity=$r.S;Reason=$r.R}}};$o}

$InappropriateDomains=@('*pornhub*','*xvideos*','*xnxx*','*redtube*','*youporn*','*xhamster*','*brazzers*','*onlyfans*','*chaturbate*','*stripchat*','*livejasmin*','*cam4*','*bongacams*','*spankbang*','*porn*','*xxx*','*hentai*','*rule34*','*nsfw*','*escort*','*adultfriend*','*bet365*','*draftkings*','*fanduel*','*bovada*','*stake.com*','*pokerstars*','*casino*','*roulette*','*sportsbook*','*slots*','*gambling*','*tinder*','*grindr*','*ashleymadison*')
$FinancialDomains=@('*paypal*','*venmo*','*cashapp*','*cash.app*','*zellepay*','*wise.com*','*stripe.com*','*chase*','*bankofamerica*','*wellsfargo*','*citibank*','*citi.com*','*usbank*','*capitalone*','*pnc.com*','*truist*','*tdbank*','*ally.com*','*discover.com*','*americanexpress*','*amex*','*schwab*','*fidelity*','*vanguard*','*etrade*','*robinhood*','*sofi.com*','*navyfederal*','*coinbase*','*binance*','*kraken*','*crypto.com*','*blockchain.com*','*metamask*','*bank*','*creditunion*','*mortgage*')
$BlockedDomains=@(
    @{D='*windows-support*';C='ScamSupport';S='Critical';R='Fake MS support'}
    @{D='*virus-alert*';C='ScamSupport';S='Critical';R='Fake alert page'}
    @{D='*geeksquad*billing*';C='ScamSupport';S='Critical';R='Refund scam lure'}
    @{D='*getintopc*';C='Warez';S='Critical';R='Pirated software'}
    @{D='*filecr*';C='Warez';S='Critical';R='Pirated software'}
    @{D='*cracked*';C='Warez';S='Critical';R='Cracks, malware'}
    @{D='*nulled*';C='Warez';S='Critical';R='Nulled software'}
    @{D='*fitgirl*';C='Warez';S='Critical';R='Game repacks, malware'}
    @{D='*1337x*';C='Torrent';S='Critical';R='Torrent index'}
    @{D='*thepiratebay*';C='Torrent';S='Critical';R='Torrent index'}
    @{D='*123movies*';C='Malvert';S='Critical';R='Piracy, malvertising'}
    @{D='*soap2day*';C='Malvert';S='Critical';R='Piracy, malvertising'}
    @{D='*popads*';C='Adware';S='Warn';R='Popunder ads'}
    @{D='*wallet-connect*';C='Phish';S='Critical';R='Wallet drainer'}
)
$SuspiciousTlds=@('.zip','.mov','.top','.xyz','.tk','.ml','.ga','.cf','.gq','.buzz','.click','.icu','.sbs','.cfd','.quest','.monster','.lol')
function Match-List{param($V,$L)foreach($p in $L){if($V -like $p){return $true}};$false}
function Test-Blocked{param($Domain,$Url='')foreach($b in $BlockedDomains){if($Domain -like $b.D -or $Url -like $b.D){return [pscustomobject]@{Category=$b.C;Severity=$b.S;Reason=$b.R}}};$null}
function Get-DomainRisk{param($Domain,$Url='')$s=0;$r=@();if(-not $Domain){return $null};$d=$Domain.ToLower()
    foreach($t in $SuspiciousTlds){if($d.EndsWith($t)){$s+=25;$r+="abuse TLD $t";break}}
    if($d -match '^(\d{1,3}\.){3}\d{1,3}$'){$s+=30;$r+='raw IP host'}
    if($d -match 'xn--'){$s+=25;$r+='punycode'}
    $h=($d -split '\.')[0]
    if($h.Length -ge 25){$s+=15;$r+='long label'}
    if((($h.ToCharArray()|Where-Object{$_ -eq '-'}).Count) -ge 3){$s+=15;$r+='many hyphens'}
    $dig=($h.ToCharArray()|Where-Object{$_ -match '\d'}).Count;if($h.Length -gt 0 -and ($dig/$h.Length) -gt 0.35){$s+=15;$r+='digit-heavy'}
    foreach($b in 'paypal','microsoft','apple','amazon','chase','coinbase','geeksquad','norton'){if($d -match $b -and $d -notmatch "(^|\.)$b\.(com|net|org)$"){$s+=35;$r+="brand '$b' off-domain";break}}
    if($h.Length -ge 8){$grp=$h.ToCharArray()|Group-Object;$e=0.0;foreach($g in $grp){$p=$g.Count/$h.Length;$e+=-1*$p*[math]::Log($p,2)};if($e -gt 3.6){$s+=20;$r+=('entropy {0:N2}'-f$e)}}
    if($Url -match '\.(exe|msi|scr|bat|ps1|vbs|jar|hta|apk)(\?|$)'){$s+=20;$r+='executable link'}
    [pscustomobject]@{Domain=$Domain;Score=[math]::Min(100,$s);Level=$(if($s-ge60){'Critical'}elseif($s-ge30){'Warn'}else{'Info'});Reasons=($r -join '; ')}}
#endregion

# ============================================================================
#region  READ-ONLY SCANS  (pure PowerShell; temp copies secure-wiped)
# ============================================================================
function Get-SystemSummary{
    Open-Sec 'System summary'
    $os=Get-CimInstance Win32_OperatingSystem;$cs=Get-CimInstance Win32_ComputerSystem;$bios=Get-CimInstance Win32_BIOS;$cpu=Get-CimInstance Win32_Processor|Select-Object -First 1
    $up=(Get-Date)-$os.LastBootUpTime;$ram=[math]::Round($cs.TotalPhysicalMemory/1GB,1)
    KV 'Hostname' $cs.Name;KV 'OS' "$($os.Caption) build $($os.BuildNumber)";KV 'Model' "$($cs.Manufacturer) $($cs.Model)";KV 'Serial' $bios.SerialNumber;KV 'CPU' $cpu.Name;KV 'RAM' "$ram GB"
    KV 'Elevated' $(if(Test-IsAdmin){'Yes'}else{'No - limited'}) $(if(Test-IsAdmin){'Ok'}else{'Warn'})
    $ut='{0}d {1}h {2}m'-f$up.Days,$up.Hours,$up.Minutes
    if($up.TotalDays-ge14){KV 'Uptime' $ut 'Warn';Add-Finding 'System' 'Warn' 'Long uptime' $ut 'Reboot to let patches finish.'}else{KV 'Uptime' $ut 'Ok'}
    $mem=[math]::Round(100-(($os.FreePhysicalMemory*1KB)/$cs.TotalPhysicalMemory*100),1);$ml=$(if($mem-ge90){'Critical'}elseif($mem-ge80){'Warn'}else{'Ok'})
    Div;Gauge 'Memory' $mem ("{0} GB used"-f[math]::Round(($cs.TotalPhysicalMemory-$os.FreePhysicalMemory*1KB)/1GB,1)) $ml
    if($ml-ne'Ok'){Add-Finding 'System' $ml 'Memory pressure' "$mem% used" 'Check runaway processes.'}
    if(-not(Test-IsAdmin)){Add-Finding 'System' 'Warn' 'Not elevated' 'No admin rights' 'Re-run as Administrator.'}
    Close-Sec
    [pscustomobject]@{OS=$os.Caption;Build=$os.BuildNumber;Model="$($cs.Manufacturer) $($cs.Model)";Serial=$bios.SerialNumber;CPU=$cpu.Name;RAMGB=$ram;Uptime=$ut;MemoryPct=$mem}}
function Get-DiskReport{
    Open-Sec "Disk usage - flag over $DiskWarnPercent%"
    $rows=@();Get-CimInstance Win32_LogicalDisk -Filter 'DriveType = 3'|ForEach-Object{if(-not $_.Size){return}
        $u=$_.Size-$_.FreeSpace;$p=[math]::Round(($u/$_.Size)*100,1);$l=$(if($p-ge90){'Critical'}elseif($p-ge$DiskWarnPercent){'Warn'}else{'Ok'})
        $d='{0} free of {1}'-f(FSize $_.FreeSpace),(FSize $_.Size);Gauge $_.DeviceID $p $d $l;$rows+=[pscustomobject]@{Drive=$_.DeviceID;Percent=$p;Detail=$d;Level=$l}
        if($l-ne'Ok'){Add-Finding 'Disk' $l "Drive $($_.DeviceID)" "$p% full, $d" $(if($p-ge90){'Urgent, under 10% free breaks updates.'}else{'Review Downloads, Disk Cleanup.'})}}
    Close-Sec;$rows}
function Get-SmartHealth{
    Open-Sec 'Drive health - SMART';$rows=@()
    try{foreach($d in Get-PhysicalDisk -EA Stop){$l=switch($d.HealthStatus){'Healthy'{'Ok'}'Warning'{'Warn'}default{'Critical'}}
        KV ("Disk {0}"-f$d.DeviceId) ("{0} [{1}] {2} {3}"-f(Clip $d.FriendlyName 26),$d.MediaType,(FSize $d.Size),$d.HealthStatus) $l
        $rel=$null;try{$rel=$d|Get-StorageReliabilityCounter -EA Stop}catch{}
        if($rel){$b=@();if($null-ne$rel.Wear){$b+="wear $($rel.Wear)%"};if($null-ne$rel.Temperature){$b+="temp $($rel.Temperature)C"};if($null-ne$rel.PowerOnHours){$b+="on $($rel.PowerOnHours)h"};if($b){Line ('    '+($b -join '   ')) 'Dim'}
            if($rel.Wear -ge 80){Add-Finding 'SMART' 'Critical' "SSD wear $($d.FriendlyName)" "$($rel.Wear)% used" 'Back up now, replace.'}elseif($rel.Wear -ge 60){Add-Finding 'SMART' 'Warn' "SSD wear $($d.FriendlyName)" "$($rel.Wear)% used" 'Budget replacement.'}
            if($rel.Temperature -ge 60){Add-Finding 'SMART' 'Warn' 'Drive temperature' "$($rel.Temperature)C" 'Check airflow.'}}
        if($d.HealthStatus -ne 'Healthy'){Add-Finding 'SMART' 'Critical' "Drive health $($d.FriendlyName)" $d.HealthStatus 'Back up, replace.'}
        $rows+=[pscustomobject]@{Disk=$d.FriendlyName;Media=$d.MediaType;Size=(FSize $d.Size);Health=$d.HealthStatus;Wear=$(if($rel){$rel.Wear});TempC=$(if($rel){$rel.Temperature});PowerOnHours=$(if($rel){$rel.PowerOnHours});Level=$l}}}catch{Stat 'Get-PhysicalDisk unavailable.' 'Info'}
    Div
    try{foreach($p in Get-CimInstance -Namespace root\WMI -ClassName MSStorageDriver_FailurePredictStatus -EA Stop){$l=$(if($p.PredictFailure){'Critical'}else{'Ok'});KV 'SMART predict' $(if($p.PredictFailure){'FAILURE PREDICTED'}else{'OK'}) $l;if($p.PredictFailure){Add-Finding 'SMART' 'Critical' 'SMART failure predicted' "reason $($p.Reason)" 'Back up now, replace.'}}}catch{KV 'SMART predict' 'Not exposed (NVMe/RAID)' 'Info'}
    Div
    Get-CimInstance Win32_LogicalDisk -Filter 'DriveType = 3'|ForEach-Object{$dr=$_.DeviceID;$o=(cmd /c "fsutil dirty query $dr" 2>&1) -join ' '
        if($o -match 'is Dirty'){KV "Dirty bit $dr" 'SET - chkdsk pending' 'Critical';Add-Finding 'SMART' 'Critical' "Dirty bit $dr" 'FS inconsistent' 'chkdsk /f then reboot.'}elseif($o -match 'is NOT Dirty'){KV "Dirty bit $dr" 'Clean' 'Ok'}}
    try{$e=Get-WinEvent -FilterHashtable @{LogName='System';ProviderName='disk','Ntfs';StartTime=(Get-Date).AddDays(-30)} -MaxEvents 200 -EA Stop|Where-Object{$_.LevelDisplayName -in 'Error','Critical'}
        if($e){KV 'Disk events (30d)' "$($e.Count) error/critical" 'Warn';Add-Finding 'SMART' 'Warn' 'Disk errors in log' "$($e.Count) in 30d" 'Correlate, back up.'}else{KV 'Disk events (30d)' 'None' 'Ok'}}catch{KV 'Disk events (30d)' 'Unavailable' 'Info'}
    Close-Sec;$rows}
function Get-FolderInventory{param($Label,$Path)
    Open-Sec "Files - $Label"
    if(-not(Test-Path $Path)){Stat "Not found: $Path" 'Warn';Close-Sec;return @()}
    $files=Get-ChildItem $Path -Recurse -File -Force -EA SilentlyContinue
    if(-not $files){Stat 'Empty.' 'Ok';Close-Sec;return @()}
    $total=($files|Measure-Object Length -Sum).Sum;KV 'Path' $Path;KV 'Files' ("{0} files, {1}"-f$files.Count,(FSize $total));Div
    $inv=foreach($f in $files){$age=[int]((Get-Date)-$f.LastWriteTime).TotalDays;$fl=New-Object System.Collections.Generic.List[string]
        if($f.Length -ge ($LargeFileMB*1MB)){$fl.Add('LARGE')};if($age -ge $StaleDays){$fl.Add('STALE')}
        if($f.Extension -match '^\.(exe|msi|bat|cmd|ps1|vbs|js|scr|jar|hta|reg|lnk|iso|img)$'){$fl.Add('EXEC')}
        if($f.Name -match '(crack|keygen|patch(er)?|activat|kms|nulled|torrent|serial)'){$fl.Add('SUSPNAME')}
        if($f.Name -match '\.(pdf|doc|docx|xls|xlsx|jpg|png|txt)\.(exe|scr|js|vbs|bat|cmd)$'){$fl.Add('DOUBLEEXT')}
        if(Get-Item $f.FullName -Stream Zone.Identifier -EA SilentlyContinue){$fl.Add('WEB')}
        $l=$(if($fl -contains 'DOUBLEEXT' -or $fl -contains 'SUSPNAME'){'Critical'}elseif($fl -contains 'EXEC' -and $fl -contains 'WEB'){'Warn'}else{'Info'})
        [pscustomobject]@{Location=$Label;Name=$f.Name;Folder=$f.DirectoryName;SizeMB=[math]::Round($f.Length/1MB,2);Modified=$f.LastWriteTime;AgeDays=$age;Flags=($fl -join ',');Level=$l}}
    $show=$inv|Where-Object{$_.Flags}|Sort-Object @{e={switch($_.Level){'Critical'{0}'Warn'{1}default{2}}}},SizeMB -Descending|Select-Object -First 20
    if($show){Line 'Flagged files (top 20):' 'Head';Grid $show @('Name','SizeMB','AgeDays','Flags') @(34,8,8,22) 'Level'}else{Stat 'No files flagged.' 'Ok'}
    foreach($r in $inv|Where-Object{$_.Level -eq 'Critical'}){Add-Finding 'Files' 'Critical' $r.Name "$($r.Folder) [$($r.Flags)]" 'Do not run, escalate.'}
    Close-Sec;$inv}
function Get-InstalledSoftware{
    Open-Sec 'Installed software'
    $keys=@('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*','HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*')
    $apps=Get-ItemProperty $keys -EA SilentlyContinue|Where-Object{$_.DisplayName -and -not $_.SystemComponent}|Select-Object @{n='Name';e={$_.DisplayName}},@{n='Version';e={$_.DisplayVersion}},@{n='Publisher';e={$_.Publisher}},@{n='Installed';e={if($_.InstallDate -match '^\d{8}$'){[datetime]::ParseExact($_.InstallDate,'yyyyMMdd',$null)}}}|Sort-Object Name -Unique
    KV 'Total programs' $apps.Count
    $recent=@($apps|Where-Object{$_.Installed -and $_.Installed -ge (Get-Date).AddDays(-30)})
    KV 'Installed in 30d' $recent.Count $(if($recent.Count -gt 5){'Warn'}else{'Info'})
    if($recent){Div;Line 'Recent installs:' 'Head';Grid ($recent|Sort-Object Installed -Descending|Select-Object Name,Version,@{n='Date';e={$_.Installed.ToString('yyyy-MM-dd')}}) @('Name','Version','Date') @(38,18,12)}
    Close-Sec;$apps}
function Test-Software{param($Apps)
    Open-Sec 'Flagged software';$fl=New-Object System.Collections.Generic.List[object]
    foreach($a in $Apps){foreach($h in Test-Suspicious $a.Name $a.Publisher){$fl.Add([pscustomobject]@{Source='Installed';Name=$a.Name;Category=$h.Category;Severity=$h.Severity;Reason=$h.Reason;Level=$h.Severity})}}
    foreach($p in Get-Process -EA SilentlyContinue|Sort-Object ProcessName -Unique){foreach($h in Test-Suspicious $p.ProcessName){$fl.Add([pscustomobject]@{Source='Running';Name=$p.ProcessName;Category=$h.Category;Severity=$h.Severity;Reason=$h.Reason;Level=$h.Severity})}}
    if(-not $fl.Count){Stat 'Nothing flagged.' 'Ok';Close-Sec;return @()}
    $s=$fl|Sort-Object @{e={switch($_.Severity){'Critical'{0}'Warn'{1}default{2}}}},Name;Grid $s @('Severity','Category','Name','Reason') @(9,11,26,28) 'Level';Div;Stat 'Nothing removed automatically.' 'Info'
    foreach($f in $s){Add-Finding 'Software' $f.Severity $f.Name "$($f.Source)/$($f.Category): $($f.Reason)" 'Confirm with user, uninstall if unwanted.'}
    Close-Sec;$s}
function Get-StartupReport{
    Open-Sec 'Startup apps';$items=New-Object System.Collections.Generic.List[object]
    function AState{param($Scope,$Kind,$Name)$root=if($Scope-eq'HKCU'){'HKCU:'}else{'HKLM:'};$path="$root\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\$Kind"
        if(-not(Test-Path $path)){return 'Unknown'};try{$v=(Get-ItemProperty $path -Name $Name -EA Stop).$Name;if($v -and $v[0] -band 1){'Disabled'}else{'Enabled'}}catch{'Enabled'}}
    foreach($rk in @(@{K='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run';Sc='HKLM';Kind='Run';T='Run (machine)'}@{K='HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run';Sc='HKLM';Kind='Run32';T='Run (x86)'}@{K='HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run';Sc='HKCU';Kind='Run';T='Run (user)'}@{K='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce';Sc='HKLM';Kind='Run';T='RunOnce (m)'}@{K='HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce';Sc='HKCU';Kind='Run';T='RunOnce (u)'})){
        if(-not(Test-Path $rk.K)){continue};$pr=Get-ItemProperty $rk.K;foreach($p in $pr.PSObject.Properties){if($p.Name -like 'PS*'){continue};$items.Add([pscustomobject]@{Name=$p.Name;Command=[string]$p.Value;Source=$rk.T;State=(AState $rk.Sc $rk.Kind $p.Name);Level='Info'})}}
    foreach($sf in @(@{P="$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup";T='Startup (user)';Sc='HKCU'}@{P="$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Startup";T='Startup (all)';Sc='HKLM'})){if(-not(Test-Path $sf.P)){continue};Get-ChildItem $sf.P -File -EA SilentlyContinue|ForEach-Object{$items.Add([pscustomobject]@{Name=$_.BaseName;Command=$_.FullName;Source=$sf.T;State=(AState $sf.Sc 'StartupFolder' $_.Name);Level='Info'})}}
    try{Get-ScheduledTask -EA Stop|Where-Object{$_.State -ne 'Disabled' -and $_.TaskPath -notlike '\Microsoft\*'}|ForEach-Object{$t=$_;$trig=$t.Triggers|Where-Object{$_.CimClass.CimClassName -match 'LogonTrigger|BootTrigger'};if($trig){$act=($t.Actions|ForEach-Object{$_.Execute}) -join ' ';$items.Add([pscustomobject]@{Name=$t.TaskName;Command=$act;Source='Sched task';State=$t.State;Level='Info'})}}}catch{}
    KV 'Startup entries' $items.Count $(if($items.Count -gt 15){'Warn'}else{'Ok'});Div
    foreach($i in $items){$h=@(Test-Suspicious $i.Name)+@(Test-Suspicious $i.Command);if($h){$i.Level=$h[0].Severity;Add-Finding 'Startup' $h[0].Severity $i.Name "$($i.Source): $($h[0].Reason)" 'Disable in Task Manager after confirming.'}elseif($i.Command -match '(AppData|Temp|ProgramData)\\'){$i.Level='Warn';Add-Finding 'Startup' 'Warn' $i.Name 'Runs from user-writable path' 'Common persistence spot, verify.'}}
    Grid ($items|Sort-Object @{e={switch($_.Level){'Critical'{0}'Warn'{1}default{2}}}},Name) @('Name','State','Source','Command') @(24,9,16,25) 'Level'
    if($items.Count -gt 15){Add-Finding 'Startup' 'Info' 'Many startup items' "$($items.Count) entries" 'Trim to speed boot.'}
    Close-Sec;$items}
function Get-SecurityPosture{
    Open-Sec 'Security posture'
    try{$mp=Get-MpComputerStatus -EA Stop;KV 'Realtime protection' $mp.RealTimeProtectionEnabled $(if($mp.RealTimeProtectionEnabled){'Ok'}else{'Critical'});KV 'Signature age' "$($mp.AntivirusSignatureAge)d" $(if($mp.AntivirusSignatureAge -le 3){'Ok'}else{'Warn'})
        if(-not $mp.RealTimeProtectionEnabled){Add-Finding 'Security' 'Critical' 'Defender realtime off' 'disabled' 'Re-enable or confirm third-party AV.'}
        if($mp.AntivirusSignatureAge -gt 7){Add-Finding 'Security' 'Warn' 'Stale AV signatures' "$($mp.AntivirusSignatureAge)d" 'Force update.'}}catch{KV 'Defender' 'Unavailable' 'Info'}
    try{Get-NetFirewallProfile -EA Stop|ForEach-Object{KV "Firewall $($_.Name)" $_.Enabled $(if($_.Enabled){'Ok'}else{'Warn'});if(-not $_.Enabled){Add-Finding 'Security' 'Warn' "Firewall off ($($_.Name))" 'disabled' 'Re-enable unless told otherwise.'}}}catch{}
    try{Get-BitLockerVolume -EA Stop|Where-Object VolumeType -eq 'OperatingSystem'|ForEach-Object{KV "BitLocker $($_.MountPoint)" $_.ProtectionStatus $(if($_.ProtectionStatus -eq 'On'){'Ok'}else{'Info'})}}catch{KV 'BitLocker' 'Unavailable' 'Info'}
    $pend=@('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending','HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')|Where-Object{Test-Path $_}
    if($pend){KV 'Reboot pending' 'Yes' 'Warn';Add-Finding 'System' 'Warn' 'Reboot pending' 'servicing waiting' 'Restart before more updates.'}else{KV 'Reboot pending' 'No' 'Ok'}
    Close-Sec}
#endregion

# ============================================================================
#region  BROWSER  (read via pure-PS regex on secure temp copies)
# ============================================================================
function Get-BrowserProfiles{
    $profiles=@()
    foreach($r in @(@{N='Chrome';P="$env:LOCALAPPDATA\Google\Chrome\User Data"}@{N='Edge';P="$env:LOCALAPPDATA\Microsoft\Edge\User Data"}@{N='Brave';P="$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data"}@{N='Vivaldi';P="$env:LOCALAPPDATA\Vivaldi\User Data"}@{N='Opera';P="$env:APPDATA\Opera Software\Opera Stable"})){
        if(-not(Test-Path $r.P)){continue};$dirs=@(Get-ChildItem $r.P -Directory -EA SilentlyContinue|Where-Object{$_.Name -eq 'Default' -or $_.Name -like 'Profile *'})
        if(-not $dirs -and (Test-Path (Join-Path $r.P 'History'))){$profiles+=[pscustomobject]@{Browser=$r.N;Profile='Default';Path=$r.P;Engine='Chromium'}}
        foreach($d in $dirs){$profiles+=[pscustomobject]@{Browser=$r.N;Profile=$d.Name;Path=$d.FullName;Engine='Chromium'}}}
    $ff="$env:APPDATA\Mozilla\Firefox\Profiles";if(Test-Path $ff){Get-ChildItem $ff -Directory -EA SilentlyContinue|ForEach-Object{$profiles+=[pscustomobject]@{Browser='Firefox';Profile=$_.Name;Path=$_.FullName;Engine='Gecko'}}}
    $profiles}
function Read-UrlsFromDb{param($Db)
    $tmp=$null;try{$tmp=New-TempCopy $Db}catch{return @()}
    $out=@();try{$raw=[IO.File]::ReadAllText($tmp,[Text.Encoding]::ASCII);foreach($m in [regex]::Matches($raw,'https?://[^\x00-\x20"''<>\\\)]{4,300}')){$out+=$m.Value}}catch{}finally{Remove-Secure $tmp}
    $out}
function Read-LoginDomains{param($Path,$Engine)
    $doms=@()
    if($Engine -eq 'Chromium'){$db=Join-Path $Path 'Login Data';if(-not(Test-Path $db)){return @()};$tmp=$null;try{$tmp=New-TempCopy $db}catch{return @()}
        try{$raw=[IO.File]::ReadAllText($tmp,[Text.Encoding]::ASCII);foreach($m in [regex]::Matches($raw,'https?://[^\x00-\x20"''<>\\\)]{4,200}')){$doms+=$m.Value}}catch{}finally{Remove-Secure $tmp}}
    else{$jf=Join-Path $Path 'logins.json';if(-not(Test-Path $jf)){return @()};try{$j=Get-Content $jf -Raw|ConvertFrom-Json;foreach($l in $j.logins){$doms+=$l.hostname}}catch{}}
    $doms|Where-Object{$_}|ForEach-Object{try{([uri]$_).Host}catch{$_}}|Sort-Object -Unique}
function Get-BrowserSafeguarding{
    Open-Sec 'Browser safeguarding + saved logins'
    if($SkipBrowser){Stat 'Skipped by -SkipBrowser.' 'Info';Close-Sec;return $null}
    $profiles=Get-BrowserProfiles;if(-not $profiles){Stat 'No browser profiles found.' 'Info';Close-Sec;return $null}
    KV 'Profiles' $profiles.Count;Div
    $extensions=New-Object System.Collections.Generic.List[object];$settings=New-Object System.Collections.Generic.List[object]
    $domainHits=New-Object System.Collections.Generic.List[object];$inappr=New-Object System.Collections.Generic.List[object]
    $finLogins=New-Object System.Collections.Generic.List[object];$inapprLogins=New-Object System.Collections.Generic.List[object]
    foreach($p in $profiles){$tag="$($p.Browser)/$($p.Profile)"
        if($p.Engine -eq 'Chromium'){
            $er=Join-Path $p.Path 'Extensions'
            if(Test-Path $er){foreach($id in Get-ChildItem $er -Directory -EA SilentlyContinue){$ver=Get-ChildItem $id.FullName -Directory -EA SilentlyContinue|Select-Object -Last 1;if(-not $ver){continue};$mf=Join-Path $ver.FullName 'manifest.json';if(-not(Test-Path $mf)){continue};try{$j=Get-Content $mf -Raw|ConvertFrom-Json}catch{continue}
                $perms=@();if($j.permissions){$perms+=$j.permissions};if($j.host_permissions){$perms+=$j.host_permissions};$risky=@($perms|Where-Object{$_ -match '<all_urls>|\*://\*/\*|webRequest|proxy|cookies|nativeMessaging|debugger|history'});$nm=if($j.name -like '__MSG*'){$id.Name}else{$j.name}
                $extensions.Add([pscustomobject]@{Browser=$tag;Name=$nm;Version=$j.version;Perms=$perms.Count;Level=$(if($risky.Count -ge 3){'Warn'}else{'Info'})});if($risky.Count -ge 3){Add-Finding 'Browser' 'Warn' "Extension: $nm" "$($p.Browser) broad perms" 'Verify deliberate.'}}}
            $pf=Join-Path $p.Path 'Preferences'
            if(Test-Path $pf){try{$j=Get-Content $pf -Raw|ConvertFrom-Json;foreach($s in @(@{K='Homepage';V=$j.homepage}@{K='Startup';V=($j.session.startup_urls -join ', ')}@{K='Search';V=$j.default_search_provider_data.template_url_data.short_name})){if(-not $s.V){continue};$bad=Test-Blocked $s.V $s.V;$l=$(if($bad){'Critical'}elseif($s.K -eq 'Search' -and $s.V -notmatch 'Google|Bing|DuckDuckGo|Yahoo|Ecosia|Startpage|Brave'){'Warn'}else{'Info'});$settings.Add([pscustomobject]@{Browser=$tag;Setting=$s.K;Value=$s.V;Level=$l});if($l -ne 'Info'){Add-Finding 'Browser' $l "$($s.K) override" "$($p.Browser): $($s.V)" 'Likely hijack, reset settings.'}}}catch{}}}
        $db=if($p.Engine -eq 'Chromium'){Join-Path $p.Path 'History'}else{Join-Path $p.Path 'places.sqlite'}
        if(Test-Path $db){$seen=@{};foreach($url in Read-UrlsFromDb $db){$dom=$null;try{$dom=([uri]$url).Host}catch{continue};if(-not $dom){continue};if($seen.ContainsKey($dom)){continue};$seen[$dom]=$true
            if(Match-List $dom $InappropriateDomains){$inappr.Add([pscustomobject]@{Browser=$tag;Domain=$dom;Level='Warn'});Add-Safeguard 'InappropriateHistory' 'Warn' $dom "$tag";continue}
            $bad=Test-Blocked $dom $url;if($bad){$domainHits.Add([pscustomobject]@{Browser=$tag;Domain=$dom;Category=$bad.Category;Score=100;Reason=$bad.Reason;Level=$bad.Severity});Add-Finding 'Browser' $bad.Severity "Blocked domain: $dom" "$($bad.Category) - $($bad.Reason)" 'Scan for adware.';continue}
            $risk=Get-DomainRisk $dom $url;if($risk -and $risk.Score -ge 30){$domainHits.Add([pscustomobject]@{Browser=$tag;Domain=$dom;Category='Heuristic';Score=$risk.Score;Reason=$risk.Reasons;Level=$risk.Level});if($risk.Score -ge 60){Add-Finding 'Browser' 'Warn' "High-risk domain: $dom" "score $($risk.Score)" 'Possible phishing/malware.'}}}}
        foreach($ld in Read-LoginDomains $p.Path $p.Engine){if(Match-List $ld $FinancialDomains){$finLogins.Add([pscustomobject]@{Browser=$tag;Domain=$ld;Path=$p.Path;Engine=$p.Engine});Add-Finding 'Credentials' 'Warn' "Saved financial login: $ld" "$tag" 'Risk on shared machine. Offer removal.'}elseif(Match-List $ld $InappropriateDomains){$inapprLogins.Add([pscustomobject]@{Browser=$tag;Domain=$ld;Path=$p.Path;Engine=$p.Engine});Add-Safeguard 'InappropriateLogin' 'Warn' $ld "$tag"}}}
    Line ("Ext {0}  SettingFlags {1}  SecDomains {2}  InapprHist {3}  FinLogins {4}  InapprLogins {5}"-f$extensions.Count,(@($settings|Where-Object Level -ne 'Info').Count),$domainHits.Count,$inappr.Count,$finLogins.Count,$inapprLogins.Count) 'Head';Div
    if($domainHits.Count){Line 'Security-flagged domains' 'Head';Grid ($domainHits|Sort-Object Score -Descending|Select-Object -First 20) @('Domain','Category','Score','Reason') @(30,12,6,26) 'Level';Div}
    if($inappr.Count){Line 'Inappropriate content in history (reported to overseers)' 'Warn';Grid ($inappr|Sort-Object Domain -Unique) @('Browser','Domain') @(24,50) 'Level';Div}
    if($finLogins.Count){Line 'Saved financial logins (domain only)' 'Warn';Grid ($finLogins|Sort-Object Domain -Unique) @('Browser','Domain') @(24,50) 'Level';Div}
    if($inapprLogins.Count){Line 'Saved inappropriate-site logins (domain only)' 'Warn';Grid ($inapprLogins|Sort-Object Domain -Unique) @('Browser','Domain') @(24,50) 'Level';Div}
    Stat 'Passwords are never decrypted or shown. Domains only.' 'Info'
    # queue deletions (need upload first)
    if($inappr.Count){foreach($g in ($inappr|Group-Object Browser)){$prof=$profiles|Where-Object{"$($_.Browser)/$($_.Profile)" -eq $g.Name}|Select-Object -First 1;$domains=@($g.Group.Domain|Sort-Object -Unique)
        Add-Action 'Safeguarding' 'Warn' ("Clear {0} inappropriate domain(s) from {1} history"-f$domains.Count,$g.Name) ($domains -join ', ') ([pscustomobject]@{Prof=$prof;Domains=$domains}) {param($c)Remove-HistoryDomains $c.Prof $c.Domains} -NeedsUpload}}
    foreach($fl in $finLogins){$prof=$profiles|Where-Object{"$($_.Browser)/$($_.Profile)" -eq $fl.Browser}|Select-Object -First 1;Add-Action 'Credentials' 'Warn' ("Remove saved financial login {0} ({1})"-f$fl.Domain,$fl.Browser) '' ([pscustomobject]@{Prof=$prof;Domain=$fl.Domain}) {param($c)Remove-LoginDomain $c.Prof $c.Domain} -NeedsUpload}
    foreach($il in $inapprLogins){$prof=$profiles|Where-Object{"$($_.Browser)/$($_.Profile)" -eq $il.Browser}|Select-Object -First 1;Add-Action 'Safeguarding' 'Warn' ("Remove saved inappropriate login {0} ({1})"-f$il.Domain,$il.Browser) '' ([pscustomobject]@{Prof=$prof;Domain=$il.Domain}) {param($c)Remove-LoginDomain $c.Prof $c.Domain} -NeedsUpload}
    Close-Sec
    [pscustomobject]@{Profiles=$profiles;Extensions=$extensions;Domains=$domainHits;Inappropriate=$inappr;FinancialLogins=$finLogins;InappropriateLogins=$inapprLogins}}
function Stop-BrowsersFor{param($Engine)$names=if($Engine -eq 'Gecko'){'firefox'}else{'chrome','msedge','brave','vivaldi','opera'};$r=Get-Process -Name $names -EA SilentlyContinue;if($r){Stat ("Closing browser: {0}"-f(($r|Select-Object -Expand Name -Unique) -join ', ')) 'Info';$r|Stop-Process -Force -EA SilentlyContinue;Start-Sleep 2}}
function Remove-HistoryDomains{param($Profile,$Domains)
    if(-not $Profile){Stat 'Profile not resolved.' 'Warn';return}
    if(-not(Get-Sqlite3)){return};Stop-BrowsersFor $Profile.Engine
    $db=if($Profile.Engine -eq 'Chromium'){Join-Path $Profile.Path 'History'}else{Join-Path $Profile.Path 'places.sqlite'}
    if(-not(Test-Path $db)){Stat 'History DB not found.' 'Warn';return}
    foreach($d in $Domains){$like=$d.Replace("'","''")
        try{if($Profile.Engine -eq 'Chromium'){Invoke-Sqlite3 $db ("DELETE FROM urls WHERE url LIKE '%{0}%'; DELETE FROM visits WHERE url NOT IN (SELECT id FROM urls);"-f$like)|Out-Null}
            else{Invoke-Sqlite3 $db ("DELETE FROM moz_historyvisits WHERE place_id IN (SELECT id FROM moz_places WHERE url LIKE '%{0}%'); DELETE FROM moz_places WHERE url LIKE '%{0}%' AND id NOT IN (SELECT fk FROM moz_bookmarks WHERE fk IS NOT NULL);"-f$like)|Out-Null}}catch{Stat "Delete failed for $d : $($_.Exception.Message)" 'Warn'}}
    Stat ("Cleared history for {0} domain(s). Record preserved in the uploaded diagnostic."-f$Domains.Count) 'Ok'}
function Remove-LoginDomain{param($Profile,$Domain)
    if(-not $Profile){Stat 'Profile not resolved.' 'Warn';return};Stop-BrowsersFor $Profile.Engine
    if($Profile.Engine -eq 'Chromium'){if(-not(Get-Sqlite3)){return};$db=Join-Path $Profile.Path 'Login Data';if(-not(Test-Path $db)){Stat 'Login DB not found.' 'Warn';return}
        try{Invoke-Sqlite3 $db ("DELETE FROM logins WHERE origin_url LIKE '%{0}%' OR signon_realm LIKE '%{0}%';"-f$Domain.Replace("'","''"))|Out-Null;Stat "Removed saved login(s) for $Domain." 'Ok'}catch{Stat "Login delete failed: $($_.Exception.Message)" 'Warn'}}
    else{$jf=Join-Path $Profile.Path 'logins.json';if(-not(Test-Path $jf)){Stat 'logins.json not found.' 'Warn';return};try{$j=Get-Content $jf -Raw|ConvertFrom-Json;$b=$j.logins.Count;$j.logins=@($j.logins|Where-Object{$_.hostname -notlike "*$Domain*"});($j|ConvertTo-Json -Depth 8)|Out-File $jf -Encoding UTF8;Stat ("Removed {0} Firefox login(s) for {1}."-f($b-$j.logins.Count),$Domain) 'Ok'}catch{Stat "Firefox login edit failed." 'Warn'}}}
#endregion

# ============================================================================
#region  TEMP + UPDATES
# ============================================================================
function Get-TempBloat{
    Open-Sec 'Temp and cache'
    $t=@(@{N='User temp';P=$env:TEMP}@{N='Windows temp';P="$env:SystemRoot\Temp"}@{N='WU cache';P="$env:SystemRoot\SoftwareDistribution\Download"}@{N='Recycle Bin';P="$env:SystemDrive\`$Recycle.Bin"})
    $tot=0;foreach($x in $t){if(-not(Test-Path $x.P)){continue};$s=(Get-ChildItem $x.P -Recurse -File -Force -EA SilentlyContinue|Measure-Object Length -Sum).Sum;if(-not $s){$s=0};$tot+=$s;KV $x.N (FSize $s)}
    Div;KV 'Reclaimable' (FSize $tot) $(if($tot-ge5GB){'Warn'}else{'Ok'})
    if($tot -ge 5GB){Add-Finding 'Disk' 'Warn' 'Temp bloat' (FSize $tot) 'Run Disk Cleanup.'}
    if($tot -ge 1GB){Add-Action 'Cleanup' 'Info' ("Open Disk Cleanup (~{0})"-f(FSize $tot)) '' ([pscustomobject]@{}) {param($c)Start-Process cleanmgr.exe -ArgumentList "/d $($env:SystemDrive.TrimEnd(':'))" -EA SilentlyContinue}}
    Close-Sec;$tot}
function Get-WindowsUpdates{
    Open-Sec 'Windows Update'
    if($SkipUpdates){Stat 'Skipped.' 'Info';Close-Sec;return @()}
    Spin 'Querying Windows Update, 30-90s...'
    try{$ses=New-Object -ComObject Microsoft.Update.Session;$sr=$ses.CreateUpdateSearcher();$res=$sr.Search("IsInstalled=0 and Type='Software' and IsHidden=0")}catch{Stat "Query failed: $($_.Exception.Message)" 'Warn';Add-Finding 'Updates' 'Warn' 'Update check failed' $_.Exception.Message 'Check wuauserv/WSUS.';Close-Sec;return @()}
    if($res.Updates.Count -eq 0){Stat 'No pending updates.' 'Ok';Close-Sec;return @()}
    $list=@();for($i=0;$i-lt$res.Updates.Count;$i++){$u=$res.Updates.Item($i);$sev=if($u.MsrcSeverity){$u.MsrcSeverity}else{'Unspecified'};$list+=[pscustomobject]@{Index=$i+1;Title=$u.Title;Severity=$sev;SizeMB=[math]::Round($u.MaxDownloadSize/1MB,1);Level=$(if($sev -in 'Critical','Important'){'Warn'}else{'Info'});Update=$u}}
    KV 'Pending updates' $list.Count 'Warn';Div;Grid $list @('Index','Severity','SizeMB','Title') @(5,11,8,48) 'Level'
    $crit=@($list|Where-Object Severity -in 'Critical','Important');Add-Finding 'Updates' $(if($crit){'Warn'}else{'Info'}) 'Pending updates' "$($list.Count) pending, $($crit.Count) crit/imp" 'Install in maintenance window.'
    Add-Action 'Updates' $(if($crit){'Warn'}else{'Info'}) ("Install Windows updates ({0} pending)"-f$list.Count) '' ([pscustomobject]@{Session=$ses;List=$list}) {param($c)Install-UpdateChoice $c.Session $c.List}
    Close-Sec;$list}
function Install-UpdateChoice{param($Session,$List)
    $crit=@($List|Where-Object Severity -in 'Critical','Important')
    Write-Host '   all | critical | 1,3,5 | none' -ForegroundColor $UI.Dim;Write-Host ("   $($G.Arrow) Which updates? ") -NoNewline -ForegroundColor $UI.Accent;$c=Read-Host
    $sel=switch -Regex ($c.Trim().ToLower()){'^all$'{$List}'^critical$'{$crit}'^[\d,\s]+$'{$nn=$c -split '[,\s]+'|Where-Object{$_}|ForEach-Object{[int]$_};$List|Where-Object{$nn -contains $_.Index}}default{@()}}
    if(-not $sel){Stat 'None selected.' 'Info';return};if(-not(Test-IsAdmin)){Stat 'Needs Administrator.' 'Critical';return}
    $coll=New-Object -ComObject Microsoft.Update.UpdateColl;foreach($s in $sel){if(-not $s.Update.EulaAccepted){$s.Update.AcceptEula()|Out-Null};$coll.Add($s.Update)|Out-Null}
    try{Write-Host "   Downloading $($coll.Count)..." -ForegroundColor $UI.Dim;$d=$Session.CreateUpdateDownloader();$d.Updates=$coll;$d.Download()|Out-Null;Write-Host '   Installing...' -ForegroundColor $UI.Dim;$ins=$Session.CreateUpdateInstaller();$ins.Updates=$coll;$r=$ins.Install()
        $codes=@{0='NotStarted';1='InProgress';2='Succeeded';3='SucceededWithErrors';4='Failed';5='Aborted'};Stat ("Result: {0}"-f$codes[[int]$r.ResultCode]) $(if($r.ResultCode -eq 2){'Ok'}else{'Warn'})
        if($r.RebootRequired -and (Ask 'Restart now?')){Restart-Computer -Force}}catch{Stat "Install failed: $($_.Exception.Message)" 'Critical'}}
#endregion

# ============================================================================
#region  DEVICE IDENTITY + APPROVAL + UPLOAD
# ============================================================================
function Get-DeviceIdentity{
    $ips=@();try{$ips=Get-NetIPAddress -AddressFamily IPv4 -EA Stop|Where-Object{$_.IPAddress -notmatch '^127\.' -and $_.PrefixOrigin -ne 'WellKnown'}|Select-Object -Expand IPAddress}catch{}
    $macs=@();try{$macs=Get-NetAdapter -EA Stop|Where-Object Status -eq 'Up'|Select-Object -Expand MacAddress}catch{}
    $pub=$null;$geo=$null;try{[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12;$g=Invoke-RestMethod 'https://ipapi.co/json/' -TimeoutSec 8 -EA Stop;$pub=$g.ip;$geo="$($g.city), $($g.region), $($g.country_name) (ISP $($g.org))"}catch{}
    [pscustomobject]@{Hostname=$env:COMPUTERNAME;LocalIPs=($ips -join ', ');MACs=($macs -join ', ');PublicIP=$pub;Geo=$geo}}
function Request-PhoneApproval{param($Device,$Intake,$RequestId)
    if($Config.ApprovalMode -eq 'None'){return 'approved'}
    $summary="DIAG {0} | {1}`nHost {2}  Pub {3}`nMAC {4}`nLoc {5}"-f$Intake.ComputerNumber,$Intake.Location,$Device.Hostname,$Device.PublicIP,$Device.MACs,$Device.Geo
    if($Config.ApprovalMode -eq 'Ntfy' -and $Config.NtfyTopic){
        $approve="$($Config.UploadEndpoint)?id=$RequestId&decision=approve&token=$($Config.UploadToken)";$deny="$($Config.UploadEndpoint)?id=$RequestId&decision=deny&token=$($Config.UploadToken)"
        try{Invoke-RestMethod "$($Config.NtfyServer)/$($Config.NtfyTopic)" -Method Post -Body $summary -Headers @{Title='Approve diagnostic upload?';Priority='high';Tags='warning';Actions="view, Approve, $approve, clear=true; view, Deny, $deny, clear=true"} -TimeoutSec 15|Out-Null;Stat 'Approval pushed to your phone. Waiting...' 'Info'}catch{Stat "Push failed: $($_.Exception.Message)" 'Warn';return 'error'}
    }elseif($Config.ApprovalMode -eq 'AppsScript'){Stat 'Approval email sent. Tap Approve on your phone. Waiting...' 'Info'}
    $deadline=(Get-Date).AddSeconds($Config.ApprovalTimeoutSec)
    while((Get-Date) -lt $deadline){Start-Sleep 4;try{$st=Invoke-RestMethod ("{0}?id={1}&action=status&token={2}"-f$Config.UploadEndpoint,$RequestId,$Config.UploadToken) -TimeoutSec 10;if($st.status -in 'approved','denied'){return $st.status}}catch{};Write-Host '.' -NoNewline -ForegroundColor $UI.Dim}
    Write-Host '';'timeout'}
function Send-Diagnostic{param($Content,$Intake,$Device,$RequestId)
    if(-not $Config.UploadEndpoint -or $Config.UploadEndpoint -match 'DEPLOY_ID'){Stat 'UploadEndpoint not configured.' 'Warn';return $null}
    Spin 'Registering diagnostic with endpoint...'
    $payload=@{action='request';id=$RequestId;filename=("DIAG-{0}-{1}.md"-f($Intake.ComputerNumber -replace '[^\w\-]','_'),(Get-Date -Format 'yyyy-MM-dd_HHmmss'));computer=$Intake.ComputerNumber;location=$Intake.Location;hostname=$Device.Hostname;publicIP=$Device.PublicIP;localIPs=$Device.LocalIPs;macs=$Device.MACs;geo=$Device.Geo;technician=$Intake.Technician;generatedAt=$Intake.Timestamp.ToString('o');content=$Content;token=$Config.UploadToken}|ConvertTo-Json -Depth 4 -Compress
    try{[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12;Invoke-RestMethod $Config.UploadEndpoint -Method Post -Body $payload -Headers @{'Content-Type'='application/json'} -TimeoutSec 60 -EA Stop|Out-Null}catch{Stat "Register failed: $($_.Exception.Message)" 'Warn';return $null}
    $decision=Request-PhoneApproval $Device $Intake $RequestId
    switch($decision){'approved'{try{$st=Invoke-RestMethod ("{0}?id={1}&action=status&token={2}"-f$Config.UploadEndpoint,$RequestId,$Config.UploadToken) -TimeoutSec 10;Stat 'Approved. Uploaded to your Drive.' 'Ok';$script:Uploaded=$true;return $st.url}catch{$script:Uploaded=$true;return '(approved)'}}'denied'{Stat 'Denied on phone. Not uploaded.' 'Warn';return $null}'timeout'{Stat 'No response. Not uploaded.' 'Warn';return $null}default{return $null}}}
#endregion

# ============================================================================
#region  ONE DIAGNOSTIC (in memory) - includes CONFIDENTIAL safeguarding section
# ============================================================================
function New-Diagnostic{param($Intake,$System,$Disks,$Smart,$Files,$Apps,$Flagged,$Startup,$Browser,$Updates,$Device)
    $date=Get-Date -Format 'yyyy-MM-dd HH:mm:ss';$sb=New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("# $date").AppendLine()
    [void]$sb.AppendLine("**Computer number:** $($Intake.ComputerNumber)  ").AppendLine("**Location:** $($Intake.Location)  ").AppendLine("**Description:** $($Intake.Description)  ").AppendLine("**Hostname:** $($Intake.Hostname)  ").AppendLine("**User:** $($Intake.User)  ").AppendLine("**Technician:** $($Intake.Technician)  ").AppendLine("**Device:** IP $($Device.PublicIP) / $($Device.LocalIPs) - MAC $($Device.MACs) - $($Device.Geo)").AppendLine()
    [void]$sb.AppendLine('## Ongoing problems reported').AppendLine();foreach($p in $Intake.Problems){[void]$sb.AppendLine("- $p")};[void]$sb.AppendLine()
    $crit=@($script:Findings|Where-Object Severity -eq 'Critical');$warn=@($script:Findings|Where-Object Severity -eq 'Warn')
    [void]$sb.AppendLine('## Summary').AppendLine().AppendLine('| | Count |').AppendLine('|---|---|').AppendLine("| Critical | $($crit.Count) |").AppendLine("| Warnings | $($warn.Count) |").AppendLine("| Safeguarding items | $($script:Safeguard.Count) |").AppendLine()
    if($script:Safeguard.Count){[void]$sb.AppendLine('## CONFIDENTIAL - SAFEGUARDING').AppendLine().AppendLine('> Preserved before any deletion. If any entry suggests exploitation of a minor, do NOT delete; preserve and contact law enforcement / your safeguarding lead.').AppendLine().AppendLine('| Time | Type | Subject | Detail |').AppendLine('|---|---|---|---|');foreach($e in $script:Safeguard){[void]$sb.AppendLine("| $($e.Time.ToString('HH:mm:ss')) | $($e.Type) | $($e.Subject) | $($e.Detail -replace '\|','/') |")};[void]$sb.AppendLine()}
    if($crit.Count -or $warn.Count){[void]$sb.AppendLine('## Action items').AppendLine().AppendLine('| Sev | Area | Item | Detail | Recommendation |').AppendLine('|---|---|---|---|---|');foreach($f in ($crit+$warn)){[void]$sb.AppendLine("| $($f.Severity) | $($f.Category) | $($f.Item) | $($f.Detail -replace '\|','/') | $($f.Recommendation -replace '\|','/') |")};[void]$sb.AppendLine()}
    [void]$sb.AppendLine('## System').AppendLine().AppendLine('| Field | Value |').AppendLine('|---|---|');foreach($p in $System.PSObject.Properties){[void]$sb.AppendLine("| $($p.Name) | $($p.Value) |")};[void]$sb.AppendLine()
    if($Smart){[void]$sb.AppendLine('## Drive health (SMART)').AppendLine().AppendLine('| Disk | Media | Size | Health | Wear % | Temp C | Power-on h |').AppendLine('|---|---|---|---|---|---|---|');foreach($s in $Smart){[void]$sb.AppendLine("| $($s.Disk) | $($s.Media) | $($s.Size) | $($s.Health) | $($s.Wear) | $($s.TempC) | $($s.PowerOnHours) |")};[void]$sb.AppendLine()}
    if($Disks){[void]$sb.AppendLine('## Disk usage').AppendLine().AppendLine('| Drive | Used % | Detail | Status |').AppendLine('|---|---|---|---|');foreach($d in $Disks){[void]$sb.AppendLine("| $($d.Drive) | $($d.Percent) | $($d.Detail) | $($d.Level) |")};[void]$sb.AppendLine()}
    [void]$sb.AppendLine('## Files (Desktop + Downloads)').AppendLine();foreach($loc in ($Files|Select-Object -Expand Location -Unique)){$set=@($Files|Where-Object Location -eq $loc);$flag=@($set|Where-Object Flags);[void]$sb.AppendLine("### $loc").AppendLine().AppendLine("- Files: $($set.Count), flagged: $($flag.Count)").AppendLine();if($flag){[void]$sb.AppendLine('| File | MB | Age | Flags |').AppendLine('|---|---|---|---|');foreach($f in ($flag|Sort-Object SizeMB -Descending|Select-Object -First 50)){[void]$sb.AppendLine("| $($f.Name -replace '\|','/') | $($f.SizeMB) | $($f.AgeDays) | $($f.Flags) |")};[void]$sb.AppendLine()}}
    [void]$sb.AppendLine('## Flagged software').AppendLine();if($Flagged){[void]$sb.AppendLine('| Sev | Category | Source | Name | Reason |').AppendLine('|---|---|---|---|---|');foreach($f in $Flagged){[void]$sb.AppendLine("| $($f.Severity) | $($f.Category) | $($f.Source) | $($f.Name -replace '\|','/') | $($f.Reason) |")}}else{[void]$sb.AppendLine('None found.')};[void]$sb.AppendLine()
    if($Startup){[void]$sb.AppendLine('## Startup apps').AppendLine().AppendLine('| Name | State | Source | Command |').AppendLine('|---|---|---|---|');foreach($s in $Startup){[void]$sb.AppendLine("| $($s.Name) | $($s.State) | $($s.Source) | $((Clip $s.Command 90) -replace '\|','/') |")};[void]$sb.AppendLine()}
    if($Browser){[void]$sb.AppendLine('## Browser').AppendLine().AppendLine("Profiles scanned: $($Browser.Profiles.Count)").AppendLine().AppendLine('> Security + safeguarding indicators only. General browsing not enumerated.').AppendLine();if($Browser.Domains.Count){[void]$sb.AppendLine('### Security-flagged domains').AppendLine().AppendLine('| Domain | Category | Score | Reason |').AppendLine('|---|---|---|---|');foreach($d in ($Browser.Domains|Sort-Object Score -Descending)){[void]$sb.AppendLine("| $($d.Domain) | $($d.Category) | $($d.Score) | $($d.Reason -replace '\|','/') |")};[void]$sb.AppendLine()};if($Browser.FinancialLogins.Count){[void]$sb.AppendLine('### Saved financial logins (domain only, passwords not read)').AppendLine().AppendLine('| Browser | Domain |').AppendLine('|---|---|');foreach($d in ($Browser.FinancialLogins|Sort-Object Domain -Unique)){[void]$sb.AppendLine("| $($d.Browser) | $($d.Domain) |")};[void]$sb.AppendLine()}}
    if($Updates){[void]$sb.AppendLine('## Pending updates').AppendLine().AppendLine('| Severity | MB | Title |').AppendLine('|---|---|---|');foreach($u in $Updates){[void]$sb.AppendLine("| $($u.Severity) | $($u.SizeMB) | $($u.Title -replace '\|','/') |")};[void]$sb.AppendLine()}
    [void]$sb.AppendLine('## Technician notes').AppendLine().AppendLine('_Add notes here._').AppendLine().AppendLine("Generated $date by $($Intake.Technician).").AppendLine().AppendLine('---')
    $sb.ToString()}
#endregion

# ============================================================================
#region  ACTION QUEUE (all prompts here; safeguarding gated on upload)
# ============================================================================
function Invoke-ActionQueue{
    Open-Sec 'Actions - confirm each (nothing above changed anything)'
    if(-not $script:Actions.Count){Stat 'No actions proposed.' 'Ok';Close-Sec;return}
    if($NonInteractive){Stat "$($script:Actions.Count) actions proposed but skipped (non-interactive)." 'Info';Close-Sec;return}
    Stat ("{0} proposed action(s)."-f$script:Actions.Count) 'Info';Div;$done=0
    foreach($a in ($script:Actions|Sort-Object @{e={switch($_.Category){'Safeguarding'{0}'Credentials'{1}'Updates'{2}default{3}}}})){
        Line ("[{0}] {1}"-f$a.Category,$a.Summary) $a.Severity;if($a.Detail){Line ('    '+(Clip $a.Detail 68)) 'Dim'}
        if($a.NeedsUpload -and -not $script:Uploaded){Stat 'BLOCKED: record was not preserved (upload denied/failed). Skipping to avoid destroying evidence.' 'Warn';Div;continue}
        if(Ask 'Do it?'){try{& $a.Do $a.Ctx;$done++}catch{Stat "Action failed: $($_.Exception.Message)" 'Warn'}}else{Stat 'Skipped.' 'Info'};Div}
    Stat "$done action(s) executed." 'Ok';Close-Sec}
#endregion

# ============================================================================
#region  MAIN
# ============================================================================
try {
    Clear-Host
    $intake = Get-Intake
    $sys     = Get-SystemSummary
    $disks   = Get-DiskReport
    $smart   = Get-SmartHealth
    $files   = @(); $files += Get-FolderInventory 'Downloads' (Join-Path $env:USERPROFILE 'Downloads'); $files += Get-FolderInventory 'Desktop' (Join-Path $env:USERPROFILE 'Desktop')
    $apps    = Get-InstalledSoftware
    $flagged = Test-Software -Apps $apps
    $startup = Get-StartupReport
    $browser = Get-BrowserSafeguarding
    Get-SecurityPosture
    $temp    = Get-TempBloat
    $updates = Get-WindowsUpdates

    Open-Sec 'Handoff'
    $device = Get-DeviceIdentity
    KV 'Hostname' $device.Hostname;KV 'Local IP' $device.LocalIPs;KV 'MAC' $device.MACs;KV 'Public IP' $device.PublicIP;KV 'Location' $device.Geo
    $md = New-Diagnostic -Intake $intake -System $sys -Disks $disks -Smart $smart -Files $files -Apps $apps -Flagged $flagged -Startup $startup -Browser $browser -Updates $updates -Device $device
    $reqId=[guid]::NewGuid().ToString('N').Substring(0,12)
    $url = Send-Diagnostic -Content $md -Intake $intake -Device $device -RequestId $reqId
    if($url){KV 'Uploaded' $url 'Ok'}
    elseif(-not $NonInteractive -and $LocalFallbackPath -and (Ask 'Upload failed. Write the diagnostic to your fallback path (e.g. USB)?')){
        try{$md|Out-File $LocalFallbackPath -Encoding UTF8;Stat "Written: $LocalFallbackPath" 'Ok'}catch{Stat "Write failed: $($_.Exception.Message)" 'Warn'}}
    else{Stat 'Not uploaded and not saved. Nothing left on this machine.' 'Info'}
    Close-Sec

    Invoke-ActionQueue

    Open-Sec 'Summary'
    $crit=@($script:Findings|Where-Object Severity -eq 'Critical');$warn=@($script:Findings|Where-Object Severity -eq 'Warn')
    KV 'Critical' $crit.Count $(if($crit.Count){'Critical'}else{'Ok'});KV 'Warnings' $warn.Count $(if($warn.Count){'Warn'}else{'Ok'});KV 'Safeguarding items' $script:Safeguard.Count $(if($script:Safeguard.Count){'Warn'}else{'Ok'});KV 'Duration' ('{0:N1}s'-f((Get-Date)-$script:StartTime).TotalSeconds)
    Close-Sec
    if($script:Safeguard.Count){Banner 'SAFEGUARDING ITEMS - REPORT TO OVERSEERS' '' $UI.Warn}
    Banner 'SCAN COMPLETE - nothing left on this machine' '' $UI.Accent
}
finally {
    Clear-Workspace
    if(-not $NonInteractive){ Write-Host ''; Write-Host '  Press Enter to clear the screen and finish...' -ForegroundColor $UI.Dim; [void](Read-Host); Clear-Host }
}
#endregion
