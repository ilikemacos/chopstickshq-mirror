# Windows analog of:
#   curl -fsSL https://chopstickshq.com/chopsticks-ai/install-csai-cli.sh | bash
#
#   irm https://chopstickshq.com/chopsticks-ai/install-csai-cli.ps1 | iex

$ErrorActionPreference = "Stop"
. ([scriptblock]::Create((Invoke-WebRequest -UseBasicParsing "https://chopstickshq.com/chopsticks-ai/install-chopsticks-ai.ps1").Content))
