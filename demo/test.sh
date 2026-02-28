#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${1:-http://127.0.0.1:8080}"
PASS=0
FAIL=0

check() {
    local label="$1" url="$2" method="${3:-GET}" data="${4:-}"
    local args=(-sS -w '\n%{http_code}' --max-time 5)
    if [ "$method" = "POST" ]; then
        args+=(-X POST -H 'Content-Type: application/json' -d "$data")
    fi
    local output
    output=$(curl "${args[@]}" "$url" 2>&1) || true
    local code
    code=$(echo "$output" | tail -1)
    local body
    body=$(echo "$output" | sed '$d')
    if [ "$code" = "200" ]; then
        echo "[PASS] $label"
        ((PASS++)) || true
    else
        echo "[FAIL] $label (HTTP $code)"
        echo "  Body: $body"
        ((FAIL++)) || true
    fi
}

echo "=== AIB Demo Integration Tests ==="
echo "Base URL: $BASE_URL"
echo ""

echo "--- Health Checks ---"
check "agent-py health"    "$BASE_URL/agents/py/health/ready"
check "mcp-node health"    "$BASE_URL/mcp/node/health/ready"
check "mcp-web health"     "$BASE_URL/mcp/web/health/ready"
check "agent-swift health" "$BASE_URL/agents/swift/health/ready"

echo ""
echo "--- MCP Node: Tools ---"
check "mcp-node list tools"     "$BASE_URL/mcp/node/mcp"
check "mcp-node calculate"      "$BASE_URL/mcp/node/mcp" POST '{"tool":"calculate","params":{"expression":"2+3*4"}}'
check "mcp-node current_time"   "$BASE_URL/mcp/node/mcp" POST '{"tool":"current_time","params":{"format":"iso"}}'
check "mcp-node transform_text" "$BASE_URL/mcp/node/mcp" POST '{"tool":"transform_text","params":{"text":"hello world","operation":"uppercase"}}'

echo ""
echo "--- MCP Web: Tools ---"
check "mcp-web list tools"    "$BASE_URL/mcp/web/mcp"
check "mcp-web fetch_url"     "$BASE_URL/mcp/web/mcp" POST '{"tool":"fetch_url","params":{"url":"https://example.com","max_length":"500"}}'
check "mcp-web extract_links" "$BASE_URL/mcp/web/mcp" POST '{"tool":"extract_links","params":{"url":"https://example.com"}}'
check "mcp-web search_page"   "$BASE_URL/mcp/web/mcp" POST '{"tool":"search_page","params":{"url":"https://example.com","query":"example"}}'

echo ""
echo "--- Agent Python: Chat (calls MCP tools from multiple servers) ---"
check "py chat calculate"   "$BASE_URL/agents/py/"     POST '{"message":"calculate 10+20"}'
check "py chat time"        "$BASE_URL/agents/py/"     POST '{"message":"what time is it"}'
check "py chat transform"   "$BASE_URL/agents/py/"     POST '{"message":"uppercase hello world"}'
check "py chat fetch"       "$BASE_URL/agents/py/"     POST '{"message":"fetch https://example.com"}'
check "py direct tool call" "$BASE_URL/agents/py/call"  POST '{"tool":"calculate","params":{"expression":"99/3"}}'
check "py list all tools"   "$BASE_URL/agents/py/tools"

echo ""
echo "--- Agent Swift: Chat (LLM + MCP tools) ---"
check "swift chat calculate" "$BASE_URL/agents/swift/" POST '{"message":"calculate 7*8"}'
check "swift list tools"     "$BASE_URL/agents/swift/tools"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
