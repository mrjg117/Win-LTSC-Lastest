# cloud-upload.ps1 —— 取代 rclone 的原生直传模块
#
# 设计目标：零第三方依赖。
#   - R2（S3 兼容）：用系统自带 curl.exe 的 --aws-sigv4 签名直传 / 列举 / 删除。
#   - SharePoint：用 Microsoft Graph REST + 应用证书(client_assertion)鉴权 + 可续传 upload session，
#     传至租户默认站点/默认文档库（app-only，无需用户 UPN），大文件(>4MB)按 320KiB 整数倍切片逐片 PUT，带进度输出。
#
# 用法（在 build_iso.yml 各步 dot-source 后调用）：
#   . self/tools/cloud-upload.ps1
#   Send-R2Upload   -Iso <path> -Tag <tag> -AccountId <x> -Bucket <b> -Region <r> -AccessKey <ak> -SecretKey <sk>
#   Invoke-R2Prune  -Tag <tag> -AccountId <x> -Bucket <b> -Region <r> -AccessKey <ak> -SecretKey <sk> -Keep <n> -Edition <e>
#   Send-SharePointUpload -Iso <path> -Tag <tag> -TenantId <t> -ClientId <c> -CertKeyPem <path> [-CertThumbprint <hex>] [-CertPem <path>] -SiteHost <host> [-Path <rootFolder>]
#   Invoke-SharePointPrune -TenantId <t> -ClientId <c> -CertKeyPem <path> [-CertThumbprint <hex>] [-CertPem <path>] -SiteHost <host> -Keep <n> -Edition <e>
#   鉴权标识：CertThumbprint（hex 指纹）与 CertPem（X.509 公钥证书 PEM）任选其一——给了证书会自动算指纹并附 x5c。私钥(CertKeyPem)始终必填。
#
# 注意：pwsh 里 `curl` 是 Invoke-WebRequest 的别名，必须显式写 `curl.exe` 才能拿到二进制。

# ---------- 通用：Base64Url ----------
function ConvertTo-Base64Url {
    param([byte[]]$Bytes)
    $s = [Convert]::ToBase64String($Bytes)
    return ($s.TrimEnd('=') -replace '\+', '-' -replace '/', '_')
}

# ---------- R2：单文件直传（S3 PUT，带进度条）----------
function Send-R2Upload {
    param(
        [string]$Iso, [string]$Tag, [string]$AccountId, [string]$Bucket,
        [string]$Region, [string]$AccessKey, [string]$SecretKey
    )
    $env:AWS_ACCESS_KEY_ID     = $AccessKey
    $env:AWS_SECRET_ACCESS_KEY = $SecretKey
    $key = "$Tag/$(Split-Path $Iso -Leaf)"
    $url = "https://$AccountId.r2.cloudflarestorage.com/$Bucket/$key"
    Write-Host "R2 上传 $Iso -> $key"
    # --aws-sigv4 自动用 AWS_ACCESS_KEY_ID/SECRET 对请求(含 body 哈希)签名；-T 流式上传、--progress-bar 显示进度
    curl.exe --aws-sigv4 "aws:amz:$Region:s3" -X PUT "$url" `
        -H "Content-Type: application/octet-stream" `
        -T "$Iso" --progress-bar
    if ($LASTEXITCODE -ne 0) { throw "R2 上传失败 (curl exit $LASTEXITCODE): $key" }
    Write-Host "R2 上传完成: $key"
}

# ---------- R2：列举顶层目录 + 删除超期目录（prune，保留 KEEP 个）----------
function Invoke-R2Prune {
    param(
        [string]$AccountId, [string]$Bucket, [string]$Region,
        [string]$AccessKey, [string]$SecretKey, [int]$Keep, [string]$Edition
    )
    $env:AWS_ACCESS_KEY_ID     = $AccessKey
    $env:AWS_SECRET_ACCESS_KEY = $SecretKey
    $endpoint = "https://$AccountId.r2.cloudflarestorage.com"
    # 顶层目录（tag 目录）用 delimiter=/ 取 CommonPrefixes
    [xml]$xml = curl.exe --aws-sigv4 "aws:amz:$Region:s3" -s "$endpoint/$Bucket`?list-type=2&delimiter=/"
    $prefixes = @($xml.ListBucketResult.CommonPrefixes | ForEach-Object { $_.Prefix.TrimEnd('/') } |
        Where-Object { $_ -like "*-$Edition" } | Sort-Object -Descending)
    $old = @($prefixes | Select-Object -Skip $Keep)
    if ($old.Count -eq 0) { Write-Host "R2 prune: 无超期目录"; return }
    foreach ($p in $old) {
        [xml]$x2 = curl.exe --aws-sigv4 "aws:amz:$Region:s3" -s "$endpoint/$Bucket`?list-type=2&prefix=$p/"
        $keys = @($x2.ListBucketResult.Contents | ForEach-Object { $_.Key })
        if ($keys.Count -eq 0) { continue }
        $body = "<Delete><Quiet>true</Quiet>" + ($keys | ForEach-Object { "<Object><Key>$_</Key></Object>" }) + "</Delete>"
        curl.exe --aws-sigv4 "aws:amz:$Region:s3" -X POST "$endpoint/$Bucket`?delete" `
            -H "Content-Type: application/xml" --data $body | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "R2 删除失败 (curl exit $LASTEXITCODE): $p" }
        Write-Host "R2 prune: 删除目录 $p ($($keys.Count) 个对象)"
    }
}

# ---------- Graph：应用证书 client_assertion 拿 token（app-only，无用户上下文）----------
function Get-GraphToken {
    param([string]$TenantId, [string]$ClientId, [string]$CertKeyPem, [string]$CertThumbprint, [string]$CertPem)
    $header = @{ alg = 'RS256'; typ = 'JWT' }
    # 公钥证书 / 指纹 任选其一：
    #  - 给了完整证书(PEM)且没给指纹 → 从证书 DER 计算 SHA1 指纹（= Azure 显示的指纹），并附 x5c 供 Entra 按公钥匹配
    #  - 给了指纹 → 直接用（原行为）
    $x5c = $null
    if ($CertPem -and (Test-Path $CertPem)) {
        $pemContent = (Get-Content $CertPem -Raw).Trim()
        if ($pemContent -ne '') {
            $pemRaw = $pemContent -replace '-----BEGIN CERTIFICATE-----', '' `
                -replace '-----END CERTIFICATE-----', '' -replace '\s+', ''
            try { $der = [Convert]::FromBase64String($pemRaw) }
            catch { throw "ONEDRIVE_CERT 不是合法的 X.509 PEM 证书: $_" }
            if ($der.Length -eq 0) { throw "ONEDRIVE_CERT 解析后为空" }
            $x5c = [Convert]::ToBase64String($der)
            if (-not $CertThumbprint) {
                $sha1 = [System.Security.Cryptography.SHA1]::Create()
                $CertThumbprint = ($sha1.ComputeHash($der) | ForEach-Object { $_.ToString('x2') }) -join ''
                Write-Host "由公钥证书推导出指纹: $CertThumbprint"
            }
        }
    }
    if (-not $CertThumbprint) { throw "必须提供 ONEDRIVE_CERT_THUMBPRINT 或 ONEDRIVE_CERT 其中之一" }
    # x5t = 证书 SHA1 指纹的 Base64Url（Entra 注册的 kid 必须匹配）
    $hb = @()
    for ($i = 0; $i -lt $CertThumbprint.Length; $i += 2) { $hb += [byte]::Parse($CertThumbprint.Substring($i, 2), 'HexNumber') }
    $header.x5t = ConvertTo-Base64Url -Bytes $hb
    if ($x5c) { $header.x5c = @($x5c) }
    $now = [DateTimeOffset]::UtcNow
    $iat = $now.ToUnixTimeSeconds()
    $claims = @{
        iss = $ClientId
        sub = $ClientId
        aud = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
        jti = [guid]::NewGuid().ToString()
        nbf = $iat
        exp = $iat + 300
    }
    $b64h = ConvertTo-Base64Url -Bytes ([System.Text.Encoding]::UTF8.GetBytes(($header | ConvertTo-Json -Compress)))
    $b64c = ConvertTo-Base64Url -Bytes ([System.Text.Encoding]::UTF8.GetBytes(($claims | ConvertTo-Json -Compress)))
    $signingInput = "$b64h.$b64c"
    $rsa = [System.Security.Cryptography.RSA]::Create()
    $rsa.ImportFromPem((Get-Content $CertKeyPem -Raw))
    $sig = $rsa.SignData([System.Text.Encoding]::UTF8.GetBytes($signingInput),
        [System.Security.Cryptography.HashAlgorithmName]::SHA256,
        [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $jwt = "$signingInput.$(ConvertTo-Base64Url -Bytes $sig)"

    $body = @{
        client_id                 = $ClientId
        scope                     = 'https://graph.microsoft.com/.default'
        grant_type                = 'client_credentials'
        client_assertion_type     = 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer'
        client_assertion          = $jwt
    }
    $r = Invoke-RestMethod -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
        -Method Post -Body $body -ContentType 'application/x-www-form-urlencoded'
    return $r.access_token
}

# ---------- SharePoint：解析默认站点 -> 默认文档库 drive ----------
# 目标：租户默认站点（根站点集合，形如 contoso.sharepoint.com）的默认文档库。
# 用应用权限（Files.ReadWrite.All / Sites.ReadWrite.All，app-only）直连站点 drive，无需任何用户 UPN。
function Resolve-SiteDrive {
    param([string]$Token, [string]$SiteHost)
    $h = @{ Authorization = "Bearer $Token" }
    # 默认站点：GET /sites/{host} 拿到根站点，其 .drive 即默认文档库
    $site = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/sites/$([System.Uri]::EscapeDataString($SiteHost))" -Headers $h -Method Get
    return $site.id   # 站点 id，用于 /sites/{id}/drive
}

# ---------- SharePoint：可续传 upload session 上传大文件 ----------
function Send-SharePointUpload {
    param(
        [string]$Iso, [string]$Tag, [string]$TenantId, [string]$ClientId,
        [string]$CertKeyPem, [string]$CertThumbprint, [string]$CertPem, [string]$SiteHost,
        [string]$Path = 'WinLTSC'
    )
    $token = Get-GraphToken -TenantId $TenantId -ClientId $ClientId -CertKeyPem $CertKeyPem -CertThumbprint $CertThumbprint -CertPem $CertPem
    $siteId = Resolve-SiteDrive -Token $token -SiteHost $SiteHost
    $driveRoot = "https://graph.microsoft.com/v1.0/sites/$([System.Uri]::EscapeDataString($siteId))/drive/root"
    $h = @{ Authorization = "Bearer $token" }
    $fileName = Split-Path $Iso -Leaf
    # 路径段编码（<Path>/<tag>/<file>），用冒号可寻址语法拿 upload session
    # Path 可含子路径（如 ISO/WinLTSC），按 / 拆段各自编码（slash 是 Graph 寻址分隔符，不能整体转义）
    $prefixSegs = @($Path -split '/' | Where-Object { $_.Trim() -ne '' } | ForEach-Object { [System.Uri]::EscapeDataString($_) })
    $seg = ($prefixSegs + [System.Uri]::EscapeDataString($Tag) + [System.Uri]::EscapeDataString($fileName)) -join '/'
    $createUrl = "$driveRoot/:$seg`:/createUploadSession"
    $sess = Invoke-RestMethod -Uri $createUrl -Method Post -Headers $h -Body '{}' -ContentType 'application/json'

    # 切片 = 5MiB，必须是 320KiB(327680) 的整数倍：5*1024*1024 / 327680 = 16.0 ✔
    $chunkSize = 5 * 1024 * 1024
    $fs = [System.IO.File]::OpenRead($Iso)
    $total = $fs.Length
    try {
        $start = 0
        while ($start -lt $total) {
            $end = [Math]::Min($start + $chunkSize, $total) - 1
            $len = $end - $start + 1
            $buf = New-Object byte[] $len
            $fs.Seek($start, [System.IO.SeekOrigin]::Begin) | Out-Null
            $read = 0
            while ($read -lt $len) { $read += $fs.Read($buf, $read, $len - $read) }
            # 临时分片文件给 Invoke-RestMethod -InFile
            $tmp = [System.IO.Path]::GetTempFileName()
            [System.IO.File]::WriteAllBytes($tmp, $buf)
            $range = "bytes $start-$end/$total"
            $ur = Invoke-RestMethod -Uri $sess.uploadUrl -Method Put -Headers @{ 'Content-Range' = $range } `
                -InFile $tmp -ContentType 'application/octet-stream'
            Remove-Item $tmp -Force
            $start = $end + 1
            Write-Host ("SharePoint 上传进度: {0:0.0}%" -f (100.0 * $start / $total))
        }
    } finally { $fs.Close() }
    Write-Host "SharePoint 上传完成: $Path/$Tag/$fileName"
}

# ---------- SharePoint：列举 + 删除（prune，保留 KEEP 个）----------
function Invoke-SharePointPrune {
    param(
        [string]$TenantId, [string]$ClientId, [string]$CertKeyPem, [string]$CertThumbprint, [string]$CertPem,
        [string]$SiteHost, [int]$Keep, [string]$Edition,
        [string]$Path = 'WinLTSC'
    )
    $token = Get-GraphToken -TenantId $TenantId -ClientId $ClientId -CertKeyPem $CertKeyPem -CertThumbprint $CertThumbprint -CertPem $CertPem
    $siteId = Resolve-SiteDrive -Token $token -SiteHost $SiteHost
    $h = @{ Authorization = "Bearer $token" }
    $pathSegs = @($Path -split '/' | Where-Object { $_.Trim() -ne '' } | ForEach-Object { [System.Uri]::EscapeDataString($_) })
    $root = "https://graph.microsoft.com/v1.0/sites/$([System.Uri]::EscapeDataString($siteId))/drive/root:/$(($pathSegs -join '/')):/children"
    $r = Invoke-RestMethod -Uri $root -Headers $h -Method Get
    # 目录名形如 <date>-<ubr>-<edition>；按名降序，Skip Keep 删最旧
    $folders = @($r.value | Where-Object { $_.folder -and $_.name -like "*-$Edition" } | Sort-Object name -Descending)
    $old = @($folders | Select-Object -Skip $Keep)
    foreach ($d in $old) {
        Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/sites/$([System.Uri]::EscapeDataString($siteId))/drive/items/$($d.id)" -Headers $h -Method Delete
        Write-Host "SharePoint prune: 删除 $($d.name)"
    }
    if ($old.Count -eq 0) { Write-Host "SharePoint prune: 无超期目录" }
}
