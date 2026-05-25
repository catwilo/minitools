#!/bin/bash

# Prompt for parameters
read -p "Workspace: " param1
read -p "Monitor: " param2

# Call your original script with the parameters
i3-msg "workspace \"$param1\"; move workspace to output $param2"
