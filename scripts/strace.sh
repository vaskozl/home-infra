#!/bin/sh
curl -v -XPATCH -H "Content-Type: application/json-patch+json" \
"http://127.0.0.1:8001/api/v1/namespaces/$1/pods/$2/ephemeralcontainers" \
--data-binary @- << EOF
[{
"op": "add", "path": "/spec/ephemeralContainers/-",
"value": {
"command":[ "/bin/sh" ],
"stdin": true, "tty": true,
"image": "nicolaka/netshoot",
"name": "debug-strace",
"securityContext": {"capabilities": {"add": ["SYS_PTRACE"]}},
"targetContainerName": "$3" }}]
EOF
