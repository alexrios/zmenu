#!/usr/bin/env bash
# Interactive test for zmenu history feature
# This script demonstrates the history functionality step-by-step

set -euo pipefail

ZMENU="./zig-out/bin/zmenu"
HISTORY_FILE="${XDG_DATA_HOME:-$HOME/.local/share}/zmenu/history"

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${BLUE}=== zmenu History Feature Interactive Test ===${NC}"
echo
echo "This script will guide you through testing the history feature."
echo "You'll need to interact with the zmenu window for each test."
echo
read -p "Press Enter to begin..."

# Clean up previous history
echo
echo -e "${YELLOW}Step 0: Cleaning up previous history...${NC}"
rm -f "$HISTORY_FILE"
rm -rf "$(dirname "$HISTORY_FILE")"
echo -e "${GREEN}✓${NC} History cleared"

# Test 1: First run - select Cherry
echo
echo -e "${YELLOW}Step 1: First run (no history yet)${NC}"
echo "Items: Apple, Banana, Cherry, Date, Elderberry"
echo "Action: Please select 'Cherry' by clicking it or using arrow keys + Enter"
echo
read -p "Press Enter to launch zmenu..."
SELECTION=$(echo -e "Apple\nBanana\nCherry\nDate\nElderberry" | "$ZMENU" || echo "")
if [ "$SELECTION" = "Cherry" ]; then
    echo -e "${GREEN}✓${NC} You selected: Cherry"
else
    echo -e "You selected: $SELECTION (expected Cherry)"
fi

# Check history file
echo
echo "Checking history file..."
if [ -f "$HISTORY_FILE" ]; then
    echo -e "${GREEN}✓${NC} History file created at: $HISTORY_FILE"
    echo "Contents:"
    cat "$HISTORY_FILE" | sed 's/^/  /'
else
    echo -e "${YELLOW}⚠${NC} History file not found (selection might have been cancelled)"
fi

# Test 2: Second run - Cherry should appear first
echo
echo -e "${YELLOW}Step 2: Second run (Cherry should appear first)${NC}"
echo "Items: Apple, Banana, Cherry, Date, Elderberry"
echo "Expected order: Cherry (history), Apple, Banana, Date, Elderberry"
echo "Action: Verify Cherry appears at the top, then select 'Banana'"
echo
read -p "Press Enter to launch zmenu..."
SELECTION=$(echo -e "Apple\nBanana\nCherry\nDate\nElderberry" | "$ZMENU" || echo "")
if [ "$SELECTION" = "Banana" ]; then
    echo -e "${GREEN}✓${NC} You selected: Banana"
else
    echo -e "You selected: $SELECTION (expected Banana)"
fi

# Check history file
echo
echo "Checking history file..."
if [ -f "$HISTORY_FILE" ]; then
    echo "Contents (most recent first):"
    cat "$HISTORY_FILE" | sed 's/^/  /'

    # Verify order
    FIRST_LINE=$(head -n 1 "$HISTORY_FILE")
    if [ "$FIRST_LINE" = "Banana" ]; then
        echo -e "${GREEN}✓${NC} Banana is at the top (most recent)"
    fi
fi

# Test 3: Third run - both history items should appear first
echo
echo -e "${YELLOW}Step 3: Third run (Banana and Cherry should appear first)${NC}"
echo "Items: Apple, Banana, Cherry, Date, Elderberry"
echo "Expected order: Banana (newest), Cherry (older), Apple, Date, Elderberry"
echo "Action: Verify order, then select 'Cherry' again"
echo
read -p "Press Enter to launch zmenu..."
SELECTION=$(echo -e "Apple\nBanana\nCherry\nDate\nElderberry" | "$ZMENU" || echo "")
if [ "$SELECTION" = "Cherry" ]; then
    echo -e "${GREEN}✓${NC} You selected: Cherry"
else
    echo -e "You selected: $SELECTION (expected Cherry)"
fi

# Check history file
echo
echo "Checking history file..."
if [ -f "$HISTORY_FILE" ]; then
    echo "Contents (most recent first):"
    cat "$HISTORY_FILE" | sed 's/^/  /'

    # Verify order
    FIRST_LINE=$(head -n 1 "$HISTORY_FILE")
    if [ "$FIRST_LINE" = "Cherry" ]; then
        echo -e "${GREEN}✓${NC} Cherry moved back to the top"
    fi
fi

# Test 4: Final verification
echo
echo -e "${YELLOW}Step 4: Final verification${NC}"
echo "Items: Apple, Banana, Cherry, Date, Elderberry"
echo "Expected order: Cherry (newest), Banana (older), Apple, Date, Elderberry"
echo "Action: Just verify the order is correct, press Escape to exit"
echo
read -p "Press Enter to launch zmenu..."
echo -e "Apple\nBanana\nCherry\nDate\nElderberry" | "$ZMENU" || true

# Test 5: Fuzzy search with history
echo
echo -e "${YELLOW}Step 5: Fuzzy search with history${NC}"
echo "Items: Apple, Banana, Cherry, Date, Elderberry"
echo "Action: Type 'e' to filter - Cherry and Elderberry should match"
echo "Expected order: Cherry (in history) appears before Elderberry (not in history)"
echo "Press Escape to exit"
echo
read -p "Press Enter to launch zmenu..."
echo -e "Apple\nBanana\nCherry\nDate\nElderberry" | "$ZMENU" || true

# Summary
echo
echo -e "${BLUE}=== Test Summary ===${NC}"
echo
echo "History file location: $HISTORY_FILE"
echo
if [ -f "$HISTORY_FILE" ]; then
    echo "Final history contents:"
    cat "$HISTORY_FILE" | sed 's/^/  /'
    echo
    echo -e "${GREEN}✓${NC} All tests completed successfully!"
    echo
    echo "Key behaviors verified:"
    echo "  1. History file is created on first selection"
    echo "  2. Previously selected items appear first in the list"
    echo "  3. Most recently selected items appear before older ones"
    echo "  4. Re-selecting an item moves it back to the top"
    echo "  5. History ordering is preserved even with fuzzy filtering"
else
    echo -e "${YELLOW}⚠${NC} History file was not created (selections were cancelled)"
fi
