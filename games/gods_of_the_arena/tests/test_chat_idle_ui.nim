import ../chatui

doAssert not humanChatVisible(false, 0)
doAssert humanChatVisible(true, 0)
doAssert humanChatVisible(false, 1)
echo "Idle empty chat is invisible; typing and messages remain visible"
