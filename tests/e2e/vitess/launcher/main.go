package main

import (
	"fmt"
	"os"

	"vitess.io/vitess/go/cmd/vtcombo/cli"
	"vitess.io/vitess/go/mysql"
)

func main() {
	authFile := os.Getenv("THYSQL_VITESS_AUTH_FILE")
	if authFile == "" {
		fatal("THYSQL_VITESS_AUTH_FILE is required")
	}

	mysql.RegisterAuthServerStaticFromParams(authFile, "", 0)

	args := replaceAuthImplementation(os.Args[1:])
	args = append(args,
		"--allow-kill-statement",
		"--mysql-server-ssl-cert=/etc/thysql-tls/server-cert.pem",
		"--mysql-server-ssl-key=/etc/thysql-tls/server-key.pem",
	)
	cli.Main.SetArgs(args)
	if err := cli.Main.Execute(); err != nil {
		fatal("vtcombo: %v", err)
	}
}

func replaceAuthImplementation(args []string) []string {
	result := make([]string, 0, len(args)+2)
	for i := 0; i < len(args); i++ {
		if args[i] == "--mysql-auth-server-impl" {
			if i+1 < len(args) {
				i++
			}
			continue
		}
		if len(args[i]) > len("--mysql-auth-server-impl=") &&
			args[i][:len("--mysql-auth-server-impl=")] == "--mysql-auth-server-impl=" {
			continue
		}
		result = append(result, args[i])
	}

	return append(result, "--mysql-auth-server-impl=static")
}

func fatal(format string, args ...any) {
	fmt.Fprintf(os.Stderr, format+"\n", args...)
	os.Exit(1)
}
