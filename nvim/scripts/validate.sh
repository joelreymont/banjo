#!/bin/bash
# Syntax validation and testing for Lua files in the Banjo Neovim plugin

set -e

cd "$(dirname "$0")/.."

echo "Validating Lua syntax..."

# Check all Lua files can be parsed
for file in lua/banjo/*.lua lua/banjo/**/*.lua; do
    if [ -f "$file" ]; then
        echo -n "  $file ... "
        if lua -e "dofile('$file')" 2>&1 | grep -q "syntax error\|'}' expected\|'end' expected"; then
            echo "FAIL"
            lua -e "dofile('$file')" 2>&1
            exit 1
        else
            echo "OK (loadable)"
        fi
    fi
done

# Check files load in Neovim context
echo "Checking module loading in Neovim..."
nvim --headless -c 'lua require("banjo").setup({auto_start = false, binary_path = "/bin/true", keymaps = false})' -c 'qa' 2>&1 | tee /tmp/banjo-validate.log
if grep -qE "Error|loop or previous error|E[0-9]+:|syntax error" /tmp/banjo-validate.log; then
    echo "FAIL: Module loading error"
    cat /tmp/banjo-validate.log
    exit 1
fi

echo "✓ Syntax checks passed"
echo ""

# Run unit tests with plenary (skip integration tests that need backend binary)
echo "Running unit tests..."
nvim --headless -c "lua vim.g.banjo_test_binary = nil" -l scripts/run_tests.lua
result=$?

if [ $result -eq 0 ]; then
    echo "✓ All tests passed"
else
    echo "✗ Tests failed"
    exit $result
fi
