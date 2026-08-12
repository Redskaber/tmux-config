#!/bin/bash
# @path: ~/.config/tmux/policy/copy/osc52.sh
# @author: redskaber
# @description: OSC 52 clipboard backend (works over SSH)

base64 | tr -d '\n' | sed 's/.*/\e]52;c;&\a/'
