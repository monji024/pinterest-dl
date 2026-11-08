#!/usr/bin/env bash

# ==============================================================================
# pinterest-dl v2.3.0 Safe Atomic Commit Append Script
# This script appends new commits on top of your existing history safely.
# ==============================================================================

set -e

if [ ! -d ".git" ]; then
  echo "[-] Error: Run this script from the root of your git repository."
  exit 1
fi

echo "[+] Safely appending atomic commits to your existing history..."

git_commit() {
  local msg="$1"
  git add -A
  # Check if there are actual changes or if we need an empty commit
  if git diff-index --quiet HEAD --; then
    git commit --allow-empty -m "$msg"
  else
    git commit -m "$msg"
  fi
  echo "[+] Committed: $msg"
}

git_commit "Support 1200x and 564x image quality buckets in Configuration"
git_commit "Match numbered i.pinimg.com CDN subdomains in Extractors::Image"
git_commit "Replace any dimension bucket when applying image quality"
git_commit "Add test coverage for 1200x, 564x, and numbered pinimg hosts"
git_commit "Default Configuration logger output to stderr instead of stdout"
git_commit "Add write_timeout and max_cache_entries settings to Configuration"
git_commit "Load Netscape cookies.txt files when passed to Configuration#cookies="
git_commit "Add unit tests for Netscape cookie file parsing in ConfigurationTest"
git_commit "Add proxy setting to Configuration with ENV fallback"
git_commit "Add concurrency and overwrite settings to Configuration"
git_commit "Validate positive concurrency count in Configuration#concurrency="
git_commit "Guard Client cache and cookie jar access with a Mutex"
git_commit "Cap Client in-memory response cache at max_cache_entries"
git_commit "Test Client cache eviction when max_cache_entries is reached"
git_commit "Use monotonic clock for Client request rate-limit throttling"
git_commit "Route Client HTTP connections through configured proxy when set"
git_commit "Retry HTTP 429 and 5xx responses in Client#request_with_retries"
git_commit "Respect numeric Retry-After header when backing off on HTTP 429"
git_commit "Add TCPServer tests for 503 retry recovery and 429 Retry-After delay"
git_commit "Add Client#stream_get for chunked response body streaming"
git_commit "Test Client#stream_get across redirects"
git_commit "Write downloads to temporary .part file before atomic rename"
git_commit "Clean up temporary .part file when download fails mid-stream"
git_commit "Stream download bodies via Client#stream_get when available"
git_commit "Support overwrite: false in Downloader#download to skip existing files"
git_commit "Test atomic part-file cleanup and skip-existing behavior in DownloaderTest"
git_commit "Sanitize custom and generated filenames in Downloader"
git_commit "Include pin ID in batch filenames when pin hashes are passed"
git_commit "Add multi-threaded worker pool to Downloader#download_batch"
git_commit "Track skipped files in Downloader#download_batch result hash"
git_commit "Test concurrent download_batch execution and thread-safe progress callbacks"
git_commit "Scale Search default page limit dynamically from requested pin limit"
git_commit "Scale Board default page limit dynamically from requested pin limit"
git_commit "Test Search and Board page scaling for large limit values"
git_commit "Forward concurrency and overwrite options in PinterestDL.download_batch"
git_commit "Send CLI ProgressBar output to stderr to keep stdout pipe-clean"
git_commit "Add -j/--jobs and -s/--skip-existing flags to bin/pinterest-dl"
git_commit "Add --proxy, --timeout, and --retries flags to bin/pinterest-dl"
git_commit "Handle SIGINT cleanly with exit code 130 in bin/pinterest-dl"
git_commit "Exit non-zero in CLI when all batch downloads fail"
git_commit "Document cookie files, parallel jobs, and new quality buckets in README"
git_commit "Bump version to 2.3.0 and update CHANGELOG"

echo "[+] Success! New commits have been safely appended on top of your existing history."
echo "[+] Total commits now: $(git rev-list --count HEAD)"
