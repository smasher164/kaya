// The scanner behind tools/check-go-env.py: which Go source reads the
// environment through Go's own copy of it.
package main

import (
	"flag"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"strconv"
	"strings"
)

// The environment READERS, which answer out of the Go runtime's envs
// slice — never filled in a c-shared library. The writers are not here on
// purpose: os.Setenv with cgo reaches libc's setenv as well.
var banned = map[string][]string{
	"os":      {"Getenv", "LookupEnv", "Environ", "ExpandEnv"},
	"syscall": {"Getenv", "Environ"},
}

// The LOCATION readers, answered out of that same copy (os.TempDir is
// Getenv("TMPDIR") with a hardcoded fallback). Not banned outright, but
// only inside a function that branches on the platform and asks the host.
var locations = map[string][]string{
	"os": {"TempDir", "UserHomeDir", "UserCacheDir", "UserConfigDir"},
}

// The import paths whose local names have to be resolved before either
// rule can read a selector.
const (
	kayaPath    = "dev.kaya/bindings/go"
	runtimePath = "runtime"
)

func inList(list []string, s string) bool {
	for _, v := range list {
		if v == s {
			return true
		}
	}
	return false
}

func isBanned(pkg, sel string) bool { return inList(banned[pkg], sel) }

func isLocation(pkg, sel string) bool { return inList(locations[pkg], sel) }

func watched(pkg string) bool { return banned[pkg] != nil || locations[pkg] != nil }

// pkgSelector answers "is this the selector <local>.<name>, with <local>
// the PACKAGE and not some variable that happens to share its name".
// Obj != nil means the parser resolved the identifier to a declaration
// in this file, i.e. a local.
func pkgSelector(sel *ast.SelectorExpr, local string) (string, bool) {
	if local == "" {
		return "", false
	}
	id, ok := sel.X.(*ast.Ident)
	if !ok || id.Obj != nil || id.Name != local {
		return "", false
	}
	return sel.Sel.Name, true
}

// branchesOnPlatform: does this function read runtime.GOOS? That is the
// one thing that makes a desktop fallback a fallback rather than the
// answer everywhere.
func branchesOnPlatform(fd *ast.FuncDecl, runtimeLocal string) bool {
	found := false
	ast.Inspect(fd, func(n ast.Node) bool {
		sel, ok := n.(*ast.SelectorExpr)
		if !ok {
			return true
		}
		if name, ok := pkgSelector(sel, runtimeLocal); ok && name == "GOOS" {
			found = true
		}
		return true
	})
	return found
}

// asksHost: does this function reach a location through the HOST's
// environment rather than Go's copy? Three spellings of one channel —
// kaya.Env/kaya.LookupEnv, C.getenv, and the unqualified pair the binding
// calls on itself. THE UNQUALIFIED FORM IS ONLY ACCEPTED WHERE IT CAN
// ONLY MEAN THAT: in a file that does not import the kaya binding.
// Accepted everywhere, a guest declaring its own `func Env(string) string`
// over os.Getenv would satisfy this check with the defect it catches.
func asksHost(fd *ast.FuncDecl, kayaLocal string) bool {
	found := false
	ast.Inspect(fd, func(n ast.Node) bool {
		switch v := n.(type) {
		case *ast.SelectorExpr:
			if name, ok := pkgSelector(v, kayaLocal); ok &&
				(name == "Env" || name == "LookupEnv") {
				found = true
			}
			if name, ok := pkgSelector(v, "C"); ok && name == "getenv" {
				found = true
			}
		case *ast.CallExpr:
			if kayaLocal != "" {
				return true
			}
			if id, ok := v.Fun.(*ast.Ident); ok &&
				(id.Name == "Env" || id.Name == "LookupEnv") {
				found = true
			}
		}
		return true
	})
	return found
}

// checkFile parses one file and reports every banned read in it, and
// every location reader that is not the fallback of a platform switch.
// Comments are not nodes, so prose ABOUT the rules costs nothing.
// Findings are TAGGED with the rule they broke ("env:" / "loc:"): the two
// want different sentences, and a diagnostic printing the wrong cause is
// worse than none.
func checkFile(name string) ([]string, error) {
	fset := token.NewFileSet()
	f, err := parser.ParseFile(fset, name, nil, parser.ParseComments)
	if err != nil {
		return nil, err
	}

	// Whatever local name each watched import was given here, plus the
	// two the location rule has to resolve to read a function's shape.
	locals := map[string]string{}
	kayaLocal, runtimeLocal := "", ""
	var found []string
	for _, imp := range f.Imports {
		p, err := strconv.Unquote(imp.Path.Value)
		if err != nil {
			continue
		}
		local := path.Base(p)
		if imp.Name != nil {
			local = imp.Name.Name
		}
		switch p {
		case kayaPath:
			if local != "_" && local != "." {
				kayaLocal = local
			}
		case runtimePath:
			if local != "_" && local != "." {
				runtimeLocal = local
			}
		}
		if !watched(p) {
			continue
		}
		switch local {
		case "_":
			continue
		case ".":
			// A dot-import puts Getenv (and TempDir) in this file's own
			// scope, where no selector expression names it. Refused
			// rather than analysed: a rule that quietly cannot see a
			// construct is this gate's own failure class.
			pos := fset.Position(imp.Pos())
			found = append(found, fmt.Sprintf(
				"env: %s:%d:%d: dot-import of %q hides the readers this gate looks for",
				name, pos.Line, pos.Column, p))
			continue
		}
		locals[local] = p
	}

	// Every location reference, with the function it sits in — matched to
	// enclosing functions afterwards, so a reference at PACKAGE level
	// (where nothing can have branched) is seen rather than missed.
	type locRef struct {
		pos  token.Position
		text string
	}
	var locRefs []locRef

	ast.Inspect(f, func(n ast.Node) bool {
		sel, ok := n.(*ast.SelectorExpr)
		if !ok {
			return true
		}
		id, ok := sel.X.(*ast.Ident)
		// Obj != nil means the parser resolved this identifier to a
		// declaration in the file — a local variable that happens to be
		// called os, not the package.
		if !ok || id.Obj != nil {
			return true
		}
		pkg, ok := locals[id.Name]
		if !ok {
			return true
		}
		pos := fset.Position(sel.Pos())
		if isBanned(pkg, sel.Sel.Name) {
			found = append(found, fmt.Sprintf("env: %s:%d:%d: %s.%s",
				name, pos.Line, pos.Column, id.Name, sel.Sel.Name))
		}
		if isLocation(pkg, sel.Sel.Name) {
			locRefs = append(locRefs, locRef{pos, id.Name + "." + sel.Sel.Name})
		}
		return true
	})

	// THE SHAPE THAT MAKES A LOCATION READER SAFE, per enclosing function:
	// it branches on runtime.GOOS and reaches a location through the host.
	// Each verdict names which half is missing — a diagnostic may only
	// print what it measured (invariant 3).
	for _, ref := range locRefs {
		var fd *ast.FuncDecl
		for _, d := range f.Decls {
			decl, ok := d.(*ast.FuncDecl)
			if !ok || decl.Body == nil {
				continue
			}
			if fset.Position(decl.Pos()).Offset <= ref.pos.Offset &&
				ref.pos.Offset <= fset.Position(decl.End()).Offset {
				fd = decl
				break
			}
		}
		where := fmt.Sprintf("loc: %s:%d:%d: %s", name, ref.pos.Line, ref.pos.Column, ref.text)
		if fd == nil {
			found = append(found, where+
				" at package level, where nothing has branched on the platform")
			continue
		}
		gotGOOS := branchesOnPlatform(fd, runtimeLocal)
		gotHost := asksHost(fd, kayaLocal)
		switch {
		case gotGOOS && gotHost:
			// The sceneRoot shape: mobile arms answered by the host,
			// this one reached only on a desktop.
		case !gotGOOS && !gotHost:
			found = append(found, fmt.Sprintf(
				"%s in func %s, which neither reads runtime.GOOS nor asks kaya for a "+
					"location — this is the answer on EVERY platform", where, fd.Name.Name))
		case !gotGOOS:
			found = append(found, fmt.Sprintf(
				"%s in func %s, which asks kaya for a location but never reads "+
					"runtime.GOOS, so this is reached on the phones too",
				where, fd.Name.Name))
		default:
			found = append(found, fmt.Sprintf(
				"%s in func %s, which reads runtime.GOOS but reaches no location "+
					"through kaya.Env — the platform arms are guesses, not the host's answer",
				where, fd.Name.Name))
		}
	}
	return found, nil
}

func main() {
	one := flag.String("file", "", "check exactly this file")
	flag.Parse()

	var files []string
	if *one != "" {
		files = []string{*one}
	} else {
		for _, root := range flag.Args() {
			err := filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
				if err != nil {
					return err
				}
				if !d.IsDir() && strings.HasSuffix(p, ".go") {
					files = append(files, p)
				}
				return nil
			})
			if err != nil {
				fmt.Fprintf(os.Stderr, "goenv: %v\n", err)
				os.Exit(2)
			}
		}
		if len(files) == 0 {
			fmt.Fprintf(os.Stderr, "goenv: the roots hold no .go files — a scan of nothing is not a pass\n")
			os.Exit(2)
		}
	}

	var all []string
	for _, f := range files {
		found, err := checkFile(f)
		if err != nil {
			fmt.Fprintf(os.Stderr, "goenv: %v\n", err)
			os.Exit(2)
		}
		all = append(all, found...)
	}
	for _, line := range all {
		fmt.Println(line)
	}
	if len(all) > 0 {
		os.Exit(1)
	}
}
