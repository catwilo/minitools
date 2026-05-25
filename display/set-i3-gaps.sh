#!/bin/bash

# Prompt for parameters
read -p "i3-gaps-size: " param1

# Call your original script with the parameters
i3-msg "gaps inner current set \"$param1\""
