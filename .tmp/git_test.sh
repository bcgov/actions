echo 'Testing git rev-parse HEAD~1...'
RESULT=$(git rev-parse HEAD~1 2>/dev/null || echo 'EMPTY')
echo 'Result: >$RESULT<'

