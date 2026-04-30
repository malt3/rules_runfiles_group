package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path"
	"path/filepath"
	"strings"

	"github.com/bazelbuild/rules_go/go/runfiles"
	"go.starlark.net/starlark"
	"go.starlark.net/syntax"
)

func main() {
	loadmapPath := flag.String("loadmap", "", "path to the loadmap file")
	propertiesPath := flag.String("properties", "", "path to the properties JSON file")
	repoName := flag.String("repo", "", "canonical name of the caller's repository")
	flag.Parse()

	if flag.NArg() != 1 {
		fmt.Fprintf(os.Stderr, "usage: %s --repo <name> [--loadmap <path>] <label>\n", os.Args[0])
		os.Exit(1)
	}

	repoMap, err := parseLoadmap(*loadmapPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "loading loadmap: %v\n", err)
		os.Exit(1)
	}

	props, err := parseProperties(*propertiesPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "loading properties: %v\n", err)
		os.Exit(1)
	}

	predeclared := starlark.StringDict{
		"read_file":    starlark.NewBuiltin("read_file", readFile),
		"get_property": starlark.NewBuiltin("get_property", makeGetProperty(props)),
	}

	opts := &syntax.FileOptions{
		TopLevelControl: true,
		GlobalReassign:  true,
	}
	ldr := &loader{
		repo:         *repoName,
		repoMap:      repoMap,
		cache:        map[string]*cacheEntry{},
		predeclared:  predeclared,
		opts:         opts,
		pathToModule: map[string]moduleLocation{},
	}

	entryLabel := flag.Arg(0)
	rloc, err := ldr.resolveLabel(entryLabel)
	if err != nil {
		fmt.Fprintf(os.Stderr, "resolving entrypoint %q: %v\n", entryLabel, err)
		os.Exit(1)
	}

	realPath, err := ldr.registerFile(rloc)
	if err != nil {
		fmt.Fprintf(os.Stderr, "loading entrypoint %q: %v\n", entryLabel, err)
		os.Exit(1)
	}

	src, err := os.ReadFile(realPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "reading %q: %v\n", realPath, err)
		os.Exit(1)
	}

	thread := &starlark.Thread{
		Name: "main",
		Load: ldr.load,
		Print: func(_ *starlark.Thread, msg string) {
			fmt.Println(msg)
		},
	}

	_, err = starlark.ExecFileOptions(opts, thread, realPath, src, predeclared)
	if err != nil {
		if evalErr, ok := err.(*starlark.EvalError); ok {
			fmt.Fprintln(os.Stderr, evalErr.Backtrace())
		} else {
			fmt.Fprintln(os.Stderr, err)
		}
		os.Exit(1)
	}
}

type moduleLocation struct {
	repo  string // canonical repo name (first path component of the rlocation path)
	rpath string // path within the repo
}

type loader struct {
	repo         string // canonical name of the caller's repository
	repoMap      map[string]string
	cache        map[string]*cacheEntry
	predeclared  starlark.StringDict
	opts         *syntax.FileOptions
	pathToModule map[string]moduleLocation
}

type cacheEntry struct {
	globals starlark.StringDict
	err     error
}

// registerFile resolves an rlocation path to a real filesystem path,
// records the reverse mapping, and returns the real path.
func (l *loader) registerFile(rloc string) (string, error) {
	absPath, err := runfiles.Rlocation(rloc)
	if err != nil {
		return "", fmt.Errorf("resolving runfile %q: %w", rloc, err)
	}
	realPath, err := filepath.EvalSymlinks(absPath)
	if err != nil {
		return "", fmt.Errorf("resolving symlinks for %q: %w", absPath, err)
	}
	repo := repoOf(rloc)
	l.pathToModule[realPath] = moduleLocation{
		repo:  repo,
		rpath: rloc[len(repo)+1:],
	}
	return realPath, nil
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

	realPath, err := l.registerFile(rloc)
	if err != nil {
		return nil, err
	}

	src, err := os.ReadFile(realPath)
	if err != nil {
		return nil, fmt.Errorf("reading %q: %w", realPath, err)
	}

	child := &starlark.Thread{
		Name: rloc,
		Load: l.load,
		Print: func(_ *starlark.Thread, msg string) {
			fmt.Println(msg)
		},
	}

	globals, execErr := starlark.ExecFileOptions(l.opts, child, realPath, src, l.predeclared)
	l.cache[rloc] = &cacheEntry{globals, execErr}
	return globals, execErr
}

func (l *loader) resolve(callerFile, module string) (string, error) {
	if strings.HasPrefix(module, "@") {
		return l.resolveExternal(module)
	}

	loc, ok := l.pathToModule[callerFile]
	if !ok {
		return "", fmt.Errorf("unknown caller %q: not tracked in module map", callerFile)
	}

	if strings.HasPrefix(module, "//") {
		return resolveRepoRelative(loc.repo, module)
	}

	module = strings.TrimPrefix(module, ":")
	return loc.repo + "/" + path.Join(path.Dir(loc.rpath), module), nil
}

// resolveLabel resolves an absolute starlark label to an rlocation path.
func (l *loader) resolveLabel(label string) (string, error) {
	if strings.HasPrefix(label, "//") {
		return resolveRepoRelative(l.repo, label)
	}
	if !strings.HasPrefix(label, "@") {
		return "", fmt.Errorf("invalid label %q: must start with @ or //", label)
	}
	return l.resolveExternal(label)
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

func parseProperties(propsRloc string) (map[string]string, error) {
	if propsRloc == "" {
		return map[string]string{}, nil
	}

	absPath, err := runfiles.Rlocation(propsRloc)
	if err != nil {
		return nil, fmt.Errorf("resolving properties %q: %w", propsRloc, err)
	}

	data, err := os.ReadFile(absPath)
	if err != nil {
		return nil, err
	}

	var m map[string]string
	if err := json.Unmarshal(data, &m); err != nil {
		return nil, fmt.Errorf("parsing properties JSON: %w", err)
	}
	return m, nil
}

func makeGetProperty(props map[string]string) func(*starlark.Thread, *starlark.Builtin, starlark.Tuple, []starlark.Tuple) (starlark.Value, error) {
	return func(thread *starlark.Thread, fn *starlark.Builtin, args starlark.Tuple, kwargs []starlark.Tuple) (starlark.Value, error) {
		var name string
		var defaultValue starlark.Value
		if err := starlark.UnpackArgs("get_property", args, kwargs, "name", &name, "default?", &defaultValue); err != nil {
			return nil, err
		}

		val, ok := props[name]
		if !ok {
			if defaultValue != nil {
				return defaultValue, nil
			}
			return nil, fmt.Errorf("get_property: unknown property %q", name)
		}
		return starlark.String(val), nil
	}
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
