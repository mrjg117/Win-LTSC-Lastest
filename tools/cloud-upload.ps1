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
#   Send-SharePointUpload -Iso <path> -TenantId <t> -ClientId <c> -CertKeyPem <path> [-CertThumbprint <hex>] [-CertPem <path>] -SiteHost <host> [-Path <subfolder>]
#       （目标 = 默认站点/默认文档库；Path 为空 -> 文档库根，非空 -> Path 子目录；绝不拼 tag 子目录）
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
    # 默认站点/默认文档库：
    #  - SiteHost 非空 -> GET /sites/{host} 取该主机根站点（如 contoso.sharepoint.com）；
    #  - SiteHost 为空 -> GET /sites/root 取租户根站点（真正的「默认站点」）。
    # 站点 .drive = 该站点的默认文档库（即 /sites/{id}/drive/root）。
    $siteUri = if ($SiteHost) {
        "https://graph.microsoft.com/v1.0/sites/$([System.Uri]::EscapeDataString($SiteHost))"
    } else {
        "https://graph.microsoft.com/v1.0/sites/root"
    }
    $site = Invoke-RestMethod -Uri $siteUri -Headers $h -Method Get
    return $site.id   # 站点 id，用于 /sites/{id}/drive
}

# ---------- SharePoint：确保目标目录存在（幂等）----------
# Graph 按路径寻址的正确语法是 drive/root:/<path>:（冒号紧贴 root，NOT drive/root/:/...）。
# 父目录缺失时 createUploadSession 会直接 400 invalidRequest；因此上传/列举前先逐段确认目录存在。
# 仅针对用户给定的 OD_PATH（Secret ONEDRIVE_PATH）：逐段 GET 探测、缺失则建；已存在跳过。
# 绝不发明额外子目录（如 <tag>）。RelativePath 为空 = 落在默认文档库根，无需建目录。
function Ensure-SharePointFolder {
    param([string]$DriveRoot, [string]$Token, [string]$RelativePath)
    # $DriveRoot = https://graph.microsoft.com/v1.0/sites/{id}/drive （默认文档库 base）
    $h = @{ Authorization = "Bearer $Token" }
    $segs = @($RelativePath -split '/' | Where-Object { $_.Trim() -ne '' })
    $acc = ''
    foreach ($seg in $segs) {
        $enc = [System.Uri]::EscapeDataString($seg)
        $accNow = if ($acc -eq '') { $enc } else { "$acc/$enc" }
        # 按路径寻址探测：drive/root:/<accNow>:
        $addr = "$DriveRoot/root:/$accNow`:"
        $exists = $false
        try { Invoke-RestMethod -Uri $addr -Headers $h -Method Get -ErrorAction Stop | Out-Null; $exists = $true } catch { $exists = $false }
        if (-not $exists) {
            # 父目录的 children 端点：根 -> drive/root/children；子目录 -> drive/root:/<parent>:/children
            $parentChildren = if ($acc -eq '') { "$DriveRoot/root/children" } else { "$DriveRoot/root:/$acc`:/children" }
            $body = (@{ name = $seg; folder = @{} } | ConvertTo-Json -Compress)
            try {
                Invoke-RestMethod -Uri $parentChildren -Headers $h -Method Post -Body $body -ContentType 'application/json' -ErrorAction Stop | Out-Null
                Write-Host "SharePoint: 创建目录 $seg (父路径=$acc)"
            } catch {
                # 并发/已存在可能 409；再 GET 确认，存在即视为成功
                $recheck = $false
                try { Invoke-RestMethod -Uri $addr -Headers $h -Method Get -ErrorAction Stop | Out-Null; $recheck = $true } catch {}
                if (-not $recheck) { throw $_ }
            }
        }
        $acc = $accNow
    }
}

# ---------- SharePoint：可续传 upload session 上传大文件 ----------
# 目标 = 默认站点/默认文档库（/sites/{id}/drive/root）下：
#   - Path 为空 -> 直接传到文档库根：drive/root:/<文件名>:
#   - Path 非空 -> 传到 Path 子目录：drive/root:/<Path>/<文件名>:
# 文件名本身含日期+UBR，足以区分构建；绝不再拼 <tag> 之类子目录。
function Send-SharePointUpload {
    param(
        [string]$Iso, [string]$TenantId, [string]$ClientId,
        [string]$CertKeyPem, [string]$CertThumbprint, [string]$CertPem, [string]$SiteHost,
        [string]$Path = ''
    )
    $token = Get-GraphToken -TenantId $TenantId -ClientId $ClientId -CertKeyPem $CertKeyPem -CertThumbprint $CertThumbprint -CertPem $CertPem
    $siteId = Resolve-SiteDrive -Token $token -SiteHost $SiteHost
    $drive = "https://graph.microsoft.com/v1.0/sites/$([System.Uri]::EscapeDataString($siteId))/drive"
    $h = @{ Authorization = "Bearer $token" }
    # 确保目标目录存在（空 Path = 默认文档库根，无需建；非空则建 Path 对应目录）
    Ensure-SharePointFolder -DriveRoot $drive -Token $token -RelativePath $Path
    $leaf = Split-Path $Iso -Leaf
    $fileNameEnc = [System.Uri]::EscapeDataString($leaf)
    # 相对路径：空 Path -> 仅文件名（落文档库根）；非空 -> Path/文件名
    $relSegs = @()
    if ($Path) { $relSegs += @($Path -split '/' | Where-Object { $_.Trim() -ne '' } | ForEach-Object { [System.Uri]::EscapeDataString($_) }) }
    $relSegs += $fileNameEnc
    $relPath = $relSegs -join '/'
    # 按路径寻址创建上传会话：drive/root:/<relPath>: （冒号紧贴 root，符合微软规范）
    $createUrl = "$drive/root:/$relPath`:/createUploadSession"
    # conflictBehavior=replace：目标文件若存在则覆盖（避免「已存在」误报 invalidRequest）
    $sessBody = (@{ '@microsoft.graph.conflictBehavior' = 'replace' } | ConvertTo-Json -Compress)
    $sess = Invoke-RestMethod -Uri $createUrl -Method Post -Headers $h -Body $sessBody -ContentType 'application/json'

    # 切片 = 50 MiB。微软硬约束：单分片 < 61,000,000 字节且必须为 320KiB(327680) 整数倍。
    # 50*1024*1024 = 52,428,800 = 160 * 327680，合法；5GB 从 ~1024 片降至 ~102 片。
    # 每片 PUT 带重试(429/5xx/网络异常) + 退避(尊重 Retry-After) + 断点续传(nextExpectedRanges)。
    # 全部用 [long](Int64)：ISO 常 > 2.147GB（Int32 上限），否则 [Math]::Min/Max
    # 在 int/long 混用时被解析到 Int32 重载，抛 "value was too large or too small for an Int32"。
    [long]$chunkSize = 50L * 1024L * 1024L
    $maxRetries = 5
    $fs = [System.IO.File]::OpenRead($Iso)
    [long]$total = $fs.Length
    try {
        [long]$start = 0
        while ($start -lt $total) {
            $end = [Math]::Min($start + $chunkSize, $total) - 1
            $len = $end - $start + 1
            $buf = New-Object byte[] $len
            $fs.Seek($start, [System.IO.SeekOrigin]::Begin) | Out-Null
            $read = 0
            while ($read -lt $len) { $read += $fs.Read($buf, $read, $len - $read) }

            $ok = $false
            $attempt = 0
            while (-not $ok -and $attempt -lt $maxRetries) {
                $attempt++
                # 临时分片文件给 Invoke-WebRequest -InFile
                $tmp = [System.IO.Path]::GetTempFileName()
                [System.IO.File]::WriteAllBytes($tmp, $buf)
                $range = "bytes $start-$end/$total"
                try {
                    # 中间片返回 202 Accepted，末片返回 200/201 Created；均不抛异常
                    Invoke-WebRequest -Uri $sess.uploadUrl -Method Put `
                        -Headers @{ 'Content-Range' = $range } -InFile $tmp `
                        -ContentType 'application/octet-stream' -TimeoutSec 600 -ErrorAction Stop | Out-Null
                    $ok = $true
                }
                catch {
                    # ---- 错误透出 + 重试判断 ----
                    $statusCode = $null
                    $respBody   = $null
                    $respObj    = $null
                    if ($_.Exception.Response) { $respObj = $_.Exception.Response }
                    if ($respObj) {
                        try { $statusCode = [int]$respObj.StatusCode } catch {}
                        try {
                            if ($respObj.Content) { $respBody = $respObj.Content }
                            else {
                                $sr = New-Object System.IO.StreamReader($respObj.GetResponseStream())
                                $respBody = $sr.ReadToEnd()
                            }
                        } catch {}
                    }
                    # 可重试：429 限流 / 5xx 服务端错误 / 网络层异常(statusCode 为空)
                    $retryable = ($statusCode -in @(429, 500, 502, 503, 504)) -or ($null -eq $statusCode)
                    if (-not $retryable -or $attempt -ge $maxRetries) {
                        if ($tmp -and (Test-Path $tmp)) { Remove-Item $tmp -Force }
                        throw ("SharePoint 分片上传失败: range=$range status=$statusCode " +
                               "attempt=$attempt/$maxRetries response=$respBody")
                    }
                    # 退避：优先尊重 Retry-After，否则指数退避 10/20/40/80/160s
                    $wait = [Math]::Pow(2, $attempt) * 5
                    if ($respObj) {
                        try {
                            if ($respObj.Headers -and $respObj.Headers.RetryAfter) {
                                $ra = $respObj.Headers.RetryAfter
                                if ($ra.Delta)    { $wait = [int]$ra.Delta.TotalSeconds }
                                elseif ($ra.Date) { $wait = [int]($ra.Date - [DateTimeOffset]::UtcNow).TotalSeconds }
                            }
                            elseif ($respObj.Headers) {
                                $raStr = $respObj.Headers.Get('Retry-After')
                                $pw = 0
                                if ($raStr -and [int]::TryParse($raStr, [ref]$pw)) { $wait = $pw }
                            }
                        } catch {}
                    }
                    if ($tmp -and (Test-Path $tmp)) { Remove-Item $tmp -Force }
                    Write-Host ("SharePoint 分片失败(status=$statusCode)，第$attempt/$maxRetries 次，" +
                                "将在 ${wait}s 后重试 range=$range")
                    Start-Sleep -Seconds $wait
                    # ---- 断点续传对齐：向会话询问 nextExpectedRanges ----
                    try {
                        $st = Invoke-RestMethod -Uri $sess.uploadUrl -Method Get -ErrorAction Stop
                        if ($st.nextExpectedRanges -and $st.nextExpectedRanges.Count -gt 0) {
                            $nr = ($st.nextExpectedRanges[0] -split '-')[0]
                            $serverStart = [long]$nr
                            if ($serverStart -gt $start) {
                                Write-Host ("SharePoint 续传对齐: 服务器已收至 $($serverStart-1)，跳至 $serverStart")
                                $start = $serverStart
                                $end = [Math]::Min($start + $chunkSize, $total) - 1
                                $len = $end - $start + 1
                                $buf = New-Object byte[] $len
                                $fs.Seek($start, [System.IO.SeekOrigin]::Begin) | Out-Null
                                $read = 0
                                while ($read -lt $len) { $read += $fs.Read($buf, $read, $len - $read) }
                            }
                        }
                    } catch {}
                }
            }
            if (-not $ok) {
                throw "SharePoint 分片上传在 $maxRetries 次重试后仍失败: range=$range"
            }
            if ($tmp -and (Test-Path $tmp)) { Remove-Item $tmp -Force }
            $start = [Math]::Max($start, $end + 1)
            Write-Host ("SharePoint 上传进度: {0:0.0}%" -f (100.0 * $start / $total))
        }
    } finally { $fs.Close() }
    Write-Host "SharePoint 上传完成: $leaf -> $Path"
}

# ---------- SharePoint：列举 + 删除（prune，保留 KEEP 个）----------
# 上传已改为平铺到 OD_PATH 下（不再按 tag 建子目录），故此处按「文件名」清理旧 ISO：
# 只删 .iso 大文件（不碰 merge.cmd / 其它文件），文件名形如 <stem>_<date>_<ubr>，按名降序即按日期降序，Skip KEEP 删最旧
function Invoke-SharePointPrune {
    param(
        [string]$TenantId, [string]$ClientId, [string]$CertKeyPem, [string]$CertThumbprint, [string]$CertPem,
        [string]$SiteHost, [int]$Keep, [string]$Edition,
        [string]$Path = ''
    )
    $token = Get-GraphToken -TenantId $TenantId -ClientId $ClientId -CertKeyPem $CertKeyPem -CertThumbprint $CertThumbprint -CertPem $CertPem
    $siteId = Resolve-SiteDrive -Token $token -SiteHost $SiteHost
    $drive = "https://graph.microsoft.com/v1.0/sites/$([System.Uri]::EscapeDataString($siteId))/drive"
    $h = @{ Authorization = "Bearer $token" }
    # 确认 OD_PATH 存在（否则下方列举会 404）；不存在则建。空 Path = 文档库根，无需建。
    Ensure-SharePointFolder -DriveRoot $drive -Token $token -RelativePath $Path
    # 列举 Path 目录下子项：空 Path -> drive/root/children；非空 -> drive/root:/<Path>:/children
    if ($Path) {
        $encPath = @($Path -split '/' | Where-Object { $_.Trim() -ne '' } | ForEach-Object { [System.Uri]::EscapeDataString($_) }) -join '/'
        $root = "$drive/root:/$encPath`:/children"
    } else {
        $root = "$drive/root/children"
    }
    $r = Invoke-RestMethod -Uri $root -Headers $h -Method Get
    # 仅 .iso 且文件名含 $Edition；按名降序即按日期降序
    $files = @($r.value | Where-Object { $_.file -and $_.name -like '*.iso' -and $_.name -like "*-$Edition*" } | Sort-Object name -Descending)
    $old = @($files | Select-Object -Skip $Keep)
    foreach ($d in $old) {
        Invoke-RestMethod -Uri "$drive/items/$($d.id)" -Headers $h -Method Delete
        Write-Host "SharePoint prune: 删除 $($d.name)"
    }
    if ($old.Count -eq 0) { Write-Host "SharePoint prune: 无超期 ISO（保留 $Keep 个）" }
}
