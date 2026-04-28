package main

import (
	"bufio"
	"flag"
	"fmt"
	"os"
	"sort"
	"strings"
)

func main() {
	output := flag.String("output", "", "output file path")
	repos := flag.String("repos", "", "path to file with repo entries (one per line, friendly\\0canonical)")
	flag.Parse()

	if *output == "" || *repos == "" {
		fmt.Fprintln(os.Stderr, "usage: loadmap_generator --output=<path> --repos=<path>")
		os.Exit(1)
	}

	f, err := os.Open(*repos)
	if err != nil {
		fmt.Fprintf(os.Stderr, "opening repos file: %v\n", err)
		os.Exit(1)
	}
	defer f.Close()

	seen := map[string]bool{}
	var entries []string

	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := scanner.Text()
		if line == "" {
			continue
		}
		parts := strings.SplitN(line, "\x00", 2)
		if len(parts) != 2 {
			fmt.Fprintf(os.Stderr, "malformed line: %q\n", line)
			os.Exit(1)
		}
		key := parts[0] + "\x00" + parts[1]
		if seen[key] {
			continue
		}
		seen[key] = true
		entries = append(entries, key)
	}
	if err := scanner.Err(); err != nil {
		fmt.Fprintf(os.Stderr, "reading repos file: %v\n", err)
		os.Exit(1)
	}

	sort.Strings(entries)

	out, err := os.Create(*output)
	if err != nil {
		fmt.Fprintf(os.Stderr, "creating output: %v\n", err)
		os.Exit(1)
	}
	defer out.Close()

	for _, entry := range entries {
		fmt.Fprintln(out, entry)
	}
}
