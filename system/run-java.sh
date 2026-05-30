#!/bin/bash

javac "$1" && java "${1%.*}" && rm "${1%.*}.class"

