# Chooses which helper AI Claude asks first when it gets stuck: muse or grok.
param([ValidateSet('muse', 'grok')] [string] $Helper = 'muse')
Set-Content 'C:\ClaudePC\helper.txt' $Helper
$names = @{ muse = 'Meta Muse'; grok = 'Grok' }
msg.exe * /time:15 "Claude will now ask $($names[$Helper]) first when it gets stuck."
