#!/bin/bash
# Fetch and display download stats for cctop releases

REPO="st0012/cctop"

data=$(gh api "repos/$REPO/releases" --jq '.[] | "\(.tag_name)\t\([.assets[].download_count] | add)"')

if [ -z "$data" ]; then
  echo "No release data found."
  exit 1
fi

total=0
printf "%-10s  %s\n" "Release" "Downloads"
printf "%-10s  %s\n" "-------" "---------"

while IFS=$'\t' read -r tag count; do
  printf "%-10s  %s\n" "$tag" "$count"
  total=$((total + count))
done <<< "$data"

printf "%-10s  %s\n" "-------" "---------"
printf "%-10s  %s\n" "Total" "$total"
