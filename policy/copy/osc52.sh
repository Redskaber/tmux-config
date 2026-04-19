#!/bin/bash
# @path: ~/.config/tmux/policy/copy/osc52.sh
# @anthor: redskaber
# @datetime: 2026-04-19
# @description: handle osc52

base64 | tr -d '\n' | sed 's/.*/\e]52;c;&\a/'
