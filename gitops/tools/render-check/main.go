// Minimal stand-in for Argo CD's ApplicationSet Go template renderer:
// text/template + missingkey=error + the sprig functions the fleet templates use,
// re-implemented with the same semantics as sprig v3.
//
// Usage: render <template-file> <params-json-file>
package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"reflect"
	"strings"
	"text/template"
)

func strval(v interface{}) string {
	switch t := v.(type) {
	case string:
		return t
	case []byte:
		return string(t)
	case error:
		return t.Error()
	case fmt.Stringer:
		return t.String()
	default:
		return fmt.Sprintf("%v", v)
	}
}

func empty(given interface{}) bool {
	g := reflect.ValueOf(given)
	if !g.IsValid() {
		return true
	}
	switch g.Kind() {
	default:
		return g.IsNil()
	case reflect.Array, reflect.Slice, reflect.Map, reflect.String:
		return g.Len() == 0
	case reflect.Bool:
		return !g.Bool()
	case reflect.Complex64, reflect.Complex128:
		return g.Complex() == 0
	case reflect.Int, reflect.Int8, reflect.Int16, reflect.Int32, reflect.Int64:
		return g.Int() == 0
	case reflect.Uint, reflect.Uint8, reflect.Uint16, reflect.Uint32, reflect.Uint64, reflect.Uintptr:
		return g.Uint() == 0
	case reflect.Float32, reflect.Float64:
		return g.Float() == 0
	case reflect.Struct:
		return false
	}
}

func dfault(d interface{}, given ...interface{}) interface{} {
	if len(given) == 0 || empty(given[0]) {
		return d
	}
	return given[0]
}

func dict(v ...interface{}) map[string]interface{} {
	d := map[string]interface{}{}
	for i := 0; i < len(v); i += 2 {
		key := strval(v[i])
		if i+1 >= len(v) {
			d[key] = ""
			continue
		}
		d[key] = v[i+1]
	}
	return d
}

func set(d map[string]interface{}, key string, value interface{}) map[string]interface{} {
	d[key] = value
	return d
}

func get(d map[string]interface{}, key string) interface{} {
	if val, ok := d[key]; ok {
		return val
	}
	return ""
}

func hasKey(d map[string]interface{}, key string) bool {
	_, ok := d[key]
	return ok
}

func dig(ps ...interface{}) (interface{}, error) {
	if len(ps) < 3 {
		return nil, errors.New("dig needs at least three arguments")
	}
	dictArg, ok := ps[len(ps)-1].(map[string]interface{})
	if !ok {
		return nil, fmt.Errorf("dig: last argument must be map[string]interface{}, got %T", ps[len(ps)-1])
	}
	def := ps[len(ps)-2]
	var cur interface{} = dictArg
	for _, k := range ps[:len(ps)-2] {
		m, ok := cur.(map[string]interface{})
		if !ok {
			return def, nil
		}
		v, ok := m[strval(k)]
		if !ok {
			return def, nil
		}
		cur = v
	}
	return cur, nil
}

func list(v ...interface{}) []interface{} { return v }

func push(l interface{}, v interface{}) ([]interface{}, error) {
	tp := reflect.TypeOf(l).Kind()
	if tp != reflect.Slice && tp != reflect.Array {
		return nil, fmt.Errorf("cannot push on type %s", tp)
	}
	l2 := reflect.ValueOf(l)
	nl := make([]interface{}, l2.Len())
	for i := 0; i < l2.Len(); i++ {
		nl[i] = l2.Index(i).Interface()
	}
	return append(nl, v), nil
}

func has(needle interface{}, haystack interface{}) (bool, error) {
	if haystack == nil {
		return false, nil
	}
	tp := reflect.TypeOf(haystack).Kind()
	if tp != reflect.Slice && tp != reflect.Array {
		return false, fmt.Errorf("cannot find has on type %s", tp)
	}
	l2 := reflect.ValueOf(haystack)
	for i := 0; i < l2.Len(); i++ {
		if reflect.DeepEqual(needle, l2.Index(i).Interface()) {
			return true, nil
		}
	}
	return false, nil
}

func toJSON(v interface{}) string {
	b, err := json.Marshal(v)
	if err != nil {
		return ""
	}
	return string(b)
}

func kindIs(target string, src interface{}) bool {
	return target == reflect.ValueOf(src).Kind().String()
}

func fail(msg string) (string, error) { return "", errors.New(msg) }

func join(sep string, v interface{}) string {
	var parts []string
	rv := reflect.ValueOf(v)
	for i := 0; i < rv.Len(); i++ {
		parts = append(parts, strval(rv.Index(i).Interface()))
	}
	return strings.Join(parts, sep)
}

func main() {
	tmplBytes, err := os.ReadFile(os.Args[1])
	if err != nil {
		panic(err)
	}
	paramBytes, err := os.ReadFile(os.Args[2])
	if err != nil {
		panic(err)
	}
	var params map[string]interface{}
	if err := json.Unmarshal(paramBytes, &params); err != nil {
		panic(err)
	}
	funcs := template.FuncMap{
		"default": dfault, "dict": dict, "set": set, "get": get, "hasKey": hasKey,
		"dig": dig, "list": list, "append": push, "has": has, "toJson": toJSON,
		"toString": strval, "kindIs": kindIs, "fail": fail, "join": join,
	}
	t, err := template.New("t").Funcs(funcs).Option("missingkey=error").Parse(string(tmplBytes))
	if err != nil {
		fmt.Fprintln(os.Stderr, "PARSE ERROR:", err)
		os.Exit(2)
	}
	var sb strings.Builder
	if err := t.Execute(&sb, params); err != nil {
		fmt.Fprintln(os.Stderr, "EXEC ERROR:", err)
		os.Exit(3)
	}
	fmt.Print(sb.String())
}
