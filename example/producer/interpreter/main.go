package main

import (
	"bufio"
	"flag"
	"fmt"
	"os"
	"path"
	"strings"

	"github.com/bazelbuild/rules_go/go/runfiles"
	"go.starlark.net/starlark"
	"go.starlark.net/syntax"
)

func main() {
	loadmapPath := flag.String("loadmap", "", "path to the loadmap file")
	flag.Parse()

	if flag.NArg() != 1 {
		fmt.Fprintf(os.Stderr, "usage: %s [--loadmap <path>] <script.star>\n", os.Args[0])
		os.Exit(1)
	}

	repoMap, err := parseLoadmap(*loadmapPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "loading loadmap: %v\n", err)
		os.Exit(1)
	}

	predeclared := starlark.StringDict{
		"read_file": starlark.NewBuiltin("read_file", readFile),
	}

	opts := &syntax.FileOptions{
		TopLevelControl: true,
		GlobalReassign:  true,
	}
	ldr := &loader{
		repoMap:     repoMap,
		cache:       map[string]*cacheEntry{},
		predeclared: predeclared,
		opts:        opts,
	}

	entryRloc := flag.Arg(0)
	absPath, err := runfiles.Rlocation(entryRloc)
	if err != nil {
		fmt.Fprintf(os.Stderr, "resolving runfile %q: %v\n", entryRloc, err)
		os.Exit(1)
	}

	src, err := os.ReadFile(absPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "reading %q: %v\n", absPath, err)
		os.Exit(1)
	}

	thread := &starlark.Thread{
		Name: "main",
		Load: ldr.load,
		Print: func(_ *starlark.Thread, msg string) {
			fmt.Println(msg)
		},
	}

	_, err = starlark.ExecFileOptions(opts, thread, entryRloc, src, predeclared)
	if err != nil {
		if evalErr, ok := err.(*starlark.EvalError); ok {
			fmt.Fprintln(os.Stderr, evalErr.Backtrace())
		} else {
			fmt.Fprintln(os.Stderr, err)
		}
		os.Exit(1)
	}
}

type loader struct {
	repoMap     map[string]string
	cache       map[string]*cacheEntry
	predeclared starlark.StringDict
	opts        *syntax.FileOptions
}

type cacheEntry struct {
	globals starlark.StringDict
	err     error
}

func (l *loader) load(thread *starlark.Thread, module string) (starlark.StringDict, error) {
	callerFile := thread.CallStack().At(0).Pos.Filename()

	rloc, err := l.resolve(callerFile, module)
	if err != nil {
		return nil, err
	}

	if entry, ok := l.cache[rloc]; ok {
		return entry.globals, entry.err
	}

	absPath, err := runfiles.Rlocation(rloc)
	if err != nil {
		return nil, fmt.Errorf("resolving %q: %w", rloc, err)
	}

	src, err := os.ReadFile(absPath)
	if err != nil {
		return nil, fmt.Errorf("reading %q: %w", absPath, err)
	}

	child := &starlark.Thread{
		Name: rloc,
		Load: l.load,
		Print: func(_ *starlark.Thread, msg string) {
			fmt.Println(msg)
		},
	}

	globals, execErr := starlark.ExecFileOptions(l.opts, child, rloc, src, l.predeclared)
	l.cache[rloc] = &cacheEntry{globals, execErr}
	return globals, execErr
}

func (l *loader) resolve(callerRloc, module string) (string, error) {
	if strings.HasPrefix(module, "@") {
		return l.resolveExternal(module)
	}
	if strings.HasPrefix(module, "//") {
		repo := repoOf(callerRloc)
		return resolveRepoRelative(repo, module)
	}
	if strings.HasPrefix(module, ":") {
		return path.Dir(callerRloc) + "/" + module[1:], nil
	}
	return path.Dir(callerRloc) + "/" + module, nil
}

func (l *loader) resolveExternal(module string) (string, error) {
	slashIdx := strings.Index(module, "//")
	if slashIdx < 0 {
		return "", fmt.Errorf("invalid load path %q: missing //", module)
	}
	friendly := module[1:slashIdx] // strip leading @
	rest := module[slashIdx+2:]    // path:file or path/file

	canonical, ok := l.repoMap[friendly]
	if !ok {
		return "", fmt.Errorf("unknown repository %q in load(%q)", friendly, module)
	}

	filePath := labelToPath(rest)
	return canonical + "/" + filePath, nil
}

func resolveRepoRelative(repo, module string) (string, error) {
	rest := module[2:]
	filePath := labelToPath(rest)
	return repo + "/" + filePath, nil
}

// labelToPath converts a label-style path like "some/path:file.star" or ":file.star"
// into a file path like "some/path/file.star" or "file.star".
func labelToPath(s string) string {
	s = strings.Replace(s, ":", "/", 1)
	s = strings.TrimPrefix(s, "/")
	return s
}

func repoOf(rlocationPath string) string {
	idx := strings.Index(rlocationPath, "/")
	if idx < 0 {
		return rlocationPath
	}
	return rlocationPath[:idx]
}

func parseLoadmap(loadmapRloc string) (map[string]string, error) {
	if loadmapRloc == "" {
		return map[string]string{}, nil
	}

	absPath, err := runfiles.Rlocation(loadmapRloc)
	if err != nil {
		return nil, fmt.Errorf("resolving loadmap %q: %w", loadmapRloc, err)
	}

	f, err := os.Open(absPath)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	m := map[string]string{}
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := scanner.Text()
		if line == "" {
			continue
		}
		parts := strings.SplitN(line, "\x00", 2)
		if len(parts) != 2 {
			return nil, fmt.Errorf("malformed loadmap line: %q", line)
		}
		m[parts[0]] = parts[1]
	}
	return m, scanner.Err()
}

func readFile(thread *starlark.Thread, fn *starlark.Builtin, args starlark.Tuple, kwargs []starlark.Tuple) (starlark.Value, error) {
	var p string
	if err := starlark.UnpackArgs("read_file", args, kwargs, "path", &p); err != nil {
		return nil, err
	}

	resolved, err := runfiles.Rlocation(p)
	if err != nil {
		return nil, fmt.Errorf("read_file: resolving %q: %w", p, err)
	}

	content, err := os.ReadFile(resolved)
	if err != nil {
		return nil, fmt.Errorf("read_file: reading %q: %w", resolved, err)
	}

	return starlark.String(string(content)), nil
}
