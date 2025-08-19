<#
generate-env.ps1
Gera um arquivo .env a partir de .env.example com prompts seguros.
Uso: execute este script no diretório onde estão .env.example e docker-compose.yml
Requisitos: PowerShell (Windows), Docker (opcional, para gerar o hash do caddy automaticamente)
#>

Set-StrictMode -Version Latest

function Read-SecureStringPlain([string]$prompt) {
    $s = Read-Host -AsSecureString $prompt
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)
    try {
        $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    } finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
    return $plain
}

# Verifica se .env.example existe
$examplePath = Join-Path -Path (Get-Location) -ChildPath '.env.example'
if (-not (Test-Path $examplePath)) {
    Write-Error ".env.example não encontrado no diretório atual. Rode o script na raiz do projeto."
    exit 1
}

# Backup .env se existir
$envPath = Join-Path -Path (Get-Location) -ChildPath '.env'
if (Test-Path $envPath) {
    $bak = "$envPath.bak_$(Get-Date -Format 'yyyyMMddHHmmss')"
    Copy-Item -Path $envPath -Destination $bak -Force
    Write-Host "Backup criado: $bak"
}

# 1) Postgres password (com confirmação)
while ($true) {
    $pg1 = Read-SecureStringPlain "Digite a senha do Postgres (evite usar '@')" 
    $pg2 = Read-SecureStringPlain "Confirme a senha do Postgres"
    if ($pg1 -eq $pg2 -and $pg1 -ne '') { $postgresPassword = $pg1; break }
    Write-Host "Senhas não conferem ou estão vazias. Tente novamente." -ForegroundColor Yellow
}

# 2) Dominio e email
$defaultDomain = 'n8nchatbot.com.br'
$domainInput = Read-Host "Digite o domínio completo para a API (ex: api.seu-dominio.com) [Enter para usar $defaultDomain]"
if ([string]::IsNullOrWhiteSpace($domainInput)) {
    $domain = $defaultDomain
} else {
    $domain = $domainInput
}

if ([string]::IsNullOrWhiteSpace($domain)) { Write-Error "Domínio obrigatório"; exit 1 }
$acmeEmail = Read-Host "Digite o e-mail para ACME/Let's Encrypt (ex: seu-email@dominio.com)"
if ([string]::IsNullOrWhiteSpace($acmeEmail)) { Write-Error "ACME email obrigatório"; exit 1 }

# 3) Manager password (para gerar hash) - confirmação
while ($true) {
    $mgr1 = Read-SecureStringPlain "Digite a senha do Manager (Basic Auth)"
    $mgr2 = Read-SecureStringPlain "Confirme a senha do Manager"
    if ($mgr1 -eq $mgr2 -and $mgr1 -ne '') { $managerPassword = $mgr1; break }
    Write-Host "Senhas não conferem ou estão vazias. Tente novamente." -ForegroundColor Yellow
}

# 4) Gerar API key (64 hex chars)
$bytes = New-Object 'System.Byte[]' 32
[System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
$apiKey = ($bytes | ForEach-Object { $_.ToString('x2') }) -join ''

# 5) Gerar hash do caddy (se docker estiver disponível)
$caddyHash = $null
if (Get-Command docker -ErrorAction SilentlyContinue) {
    Write-Host "Docker detectado. Gerando hash do Caddy..."
    # Chamamos docker para gerar o hash; cuidado ao passar a senha em linha de comando
    try {
        $processInfo = New-Object System.Diagnostics.ProcessStartInfo
        $processInfo.FileName = 'docker'
        $processInfo.Arguments = "run --rm caddy caddy hash-password --plaintext `"$managerPassword`""
        $processInfo.RedirectStandardOutput = $true
        $processInfo.RedirectStandardError = $true
        $processInfo.UseShellExecute = $false
        $p = [System.Diagnostics.Process]::Start($processInfo)
        $stdout = $p.StandardOutput.ReadToEnd()
        $stderr = $p.StandardError.ReadToEnd()
        $p.WaitForExit()
        if ($p.ExitCode -eq 0) {
            $caddyHash = $stdout.Trim()
            Write-Host "Hash gerado com sucesso." -ForegroundColor Green
        } else {
            Write-Warning "Falha ao gerar hash via docker. Saída: $stderr"
        }
    } catch {
        Write-Warning "Erro ao executar docker para gerar o hash: $_"
    }
} else {
    Write-Host "Docker não encontrado: você precisará gerar o hash manualmente com:" -ForegroundColor Yellow
    Write-Host "docker run --rm caddy caddy hash-password --plaintext 'SUA_SENHA'"
}

# Se não geramos o hash automaticamente, pede para colar
if (-not $caddyHash) {
    $caddyHash = Read-Host "Cole aqui o hash gerado pelo comando do Caddy (ou gere manualmente e cole)"
    if ([string]::IsNullOrWhiteSpace($caddyHash)) { Write-Error "Hash do Caddy é obrigatório"; exit 1 }
}

# 6) Preparar DATABASE_CONNECTION_URI (escapa '@' na senha)
$escapedPg = $postgresPassword -replace '@', '%40'
$databaseUri = "postgresql://evolution:$escapedPg@postgres:5432/evolution"

# 7) Montar conteúdo do .env
$envLines = @()
$envLines += "# ===== AUTH DA EVOLUTION ====="
$envLines += "AUTHENTICATION_API_KEY=$apiKey"
$envLines += ""
$envLines += "# ===== POSTGRES ====="
$envLines += "POSTGRES_PASSWORD=$postgresPassword"
$envLines += "POSTGRES_DB=evolution"
$envLines += "POSTGRES_USER=evolution"
$envLines += "DATABASE_ENABLED=true"
$envLines += "DATABASE_PROVIDER=postgresql"
$envLines += "DATABASE_CONNECTION_URI=$databaseUri"
$envLines += ""
$envLines += "# ===== CACHE (sem Redis no Free Tier) ====="
$envLines += "CACHE_REDIS_ENABLED=false"
$envLines += "CACHE_LOCAL_ENABLED=true"
$envLines += ""
$envLines += "# ===== LOG ====="
$envLines += "LOG_LEVEL=info"
$envLines += ""
$envLines += "# ===== DOMÍNIO / SSL ====="
$envLines += "DOMAIN=$domain"
$envLines += "ACME_EMAIL=$acmeEmail"
$envLines += ""
$envLines += "# ===== BASIC AUTH no /manager (Caddy) ====="
$envLines += "BASIC_AUTH_USER=admin"
$envLines += "BASIC_AUTH_HASH=$caddyHash"

# 8) Escrever arquivo .env
$envContent = $envLines -join "`n"
try {
    $envContent | Out-File -FilePath $envPath -Encoding utf8 -Force
    Write-Host ".env criado em: $envPath" -ForegroundColor Green
} catch {
    Write-Error "Falha ao escrever .env: $_"
    exit 1
}

# 9) Limpar variáveis sensíveis da memória
$postgresPassword = $null
$managerPassword = $null
$pg1 = $null; $pg2 = $null; $mgr1 = $null; $mgr2 = $null

# 10) Dicas finais
Write-Host "\nPróximos passos:" -ForegroundColor Cyan
Write-Host " - Verifique o arquivo .env (não comite no git)."
Write-Host " - Rode: docker compose pull; docker compose up -d"
Write-Host " - Monitore logs: docker logs -f evolution_caddy e docker logs -f evolution_api"

Write-Host "Script finalizado." -ForegroundColor Green
