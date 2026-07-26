[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$CatalogPath,

    [string]$ListenPrefix = 'http://+:8080/webbff/v1/products/'
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $CatalogPath)) {
    throw "Catalog file '$CatalogPath' was not found."
}

$catalog = Get-Content -LiteralPath $CatalogPath -Raw | ConvertFrom-Json
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add($ListenPrefix)
$listener.Start()

try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        $response = $context.Response

        try {
            $productCode = $context.Request.Url.Segments[-1].Trim('/')
            $product = @($catalog | Where-Object { $_.code -eq $productCode }) | Select-Object -First 1

            if ($context.Request.HttpMethod -ne 'GET') {
                $response.StatusCode = [int][System.Net.HttpStatusCode]::MethodNotAllowed
                $payload = @{ error = 'Only GET is supported.' }
            }
            elseif ($null -eq $product) {
                $response.StatusCode = [int][System.Net.HttpStatusCode]::NotFound
                $payload = @{ error = 'Product not found.' }
            }
            else {
                $response.StatusCode = [int][System.Net.HttpStatusCode]::OK
                $payload = @{ name = [string]$product.name; price = [decimal]$product.price }
            }

            $bytes = [System.Text.Encoding]::UTF8.GetBytes(($payload | ConvertTo-Json -Compress))
            $response.ContentType = 'application/json; charset=utf-8'
            $response.ContentLength64 = $bytes.Length
            $response.OutputStream.Write($bytes, 0, $bytes.Length)
        }
        catch {
            $response.StatusCode = [int][System.Net.HttpStatusCode]::InternalServerError
        }
        finally {
            $response.Close()
        }
    }
}
finally {
    $listener.Close()
}