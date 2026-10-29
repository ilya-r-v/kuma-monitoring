// Модуль управляет локальным контуром мониторинга Uptime Kuma через Docker хоста
package main

import (
	"context"
	"time"

	"dagger/kuma-monitoring/internal/dagger"
)

type KumaMonitoring struct{}

const ensureNetwork = "docker network inspect kuma-net >/dev/null 2>&1 || docker network create kuma-net"

func dockerCli(src *dagger.Directory, sock *dagger.Socket) *dagger.Container {
	return dag.Container().
		From("docker:29-cli").
		WithUnixSocket("/var/run/docker.sock", sock).
		WithDirectory("/src", src).
		WithWorkdir("/src").
		// Dagger кеширует результаты exec. Без этой переменной повторный
		// запуск взял бы результат из кеша и ничего бы не задеплоил.
		WithEnvVariable("CACHE_BUSTER", time.Now().String())
}

// DeployApp разворачивает MariaDB + Uptime Kuma.
func (m *KumaMonitoring) DeployApp(
	ctx context.Context,
	// +defaultPath="/"
	// +ignore=[".git", "**/.env", ".dagger"]
	src *dagger.Directory,
	sock *dagger.Socket,
	dbRootPassword *dagger.Secret,
	dbPassword *dagger.Secret,
	exporterPassword *dagger.Secret,
) (string, error) {
	return dockerCli(src, sock).
		WithSecretVariable("DB_ROOT_PASSWORD", dbRootPassword).
		WithSecretVariable("DB_PASSWORD", dbPassword).
		WithSecretVariable("EXP_PW", exporterPassword).
		WithExec([]string{"sh", "-c", ensureNetwork}).
		WithExec([]string{"docker", "compose", "-f", "app/compose.yml", "up", "-d", "--wait"}).
		WithExec([]string{"sh", "scripts/create-exporter-user.sh"}).
		WithExec([]string{"docker", "compose", "-f", "app/compose.yml", "ps"}).
		Stdout(ctx)
}

// DeployMonitoring разворачивает Prometheus, Grafana и экспортеры.
func (m *KumaMonitoring) DeployMonitoring(
	ctx context.Context,
	// +defaultPath="/"
	// +ignore=[".git", "**/.env", ".dagger"]
	src *dagger.Directory,
	sock *dagger.Socket,
	grafanaPassword *dagger.Secret,
	exporterPassword *dagger.Secret,
) (string, error) {
	return dockerCli(src, sock).
		WithSecretVariable("GRAFANA_ADMIN_PASSWORD", grafanaPassword).
		WithSecretVariable("EXPORTER_DB_PASSWORD", exporterPassword).
		WithExec([]string{"sh", "-c", ensureNetwork}).
		WithExec([]string{"docker", "compose", "-f", "monitoring/compose.yml", "up", "-d", "--build", "--wait"}).
		WithExec([]string{"docker", "compose", "-f", "monitoring/compose.yml", "ps"}).
		Stdout(ctx)
}

// ConfigureGrafana настраивает datasource
func (m *KumaMonitoring) ConfigureGrafana(
	ctx context.Context,
	// +defaultPath="/"
	// +ignore=[".git", "**/.env", ".dagger"]
	src *dagger.Directory,
	// Grafana на хосте, например tcp://localhost:3000
	grafana *dagger.Service,
	grafanaPassword *dagger.Secret,
	// +optional
	// +default="admin"
	grafanaUser string,
) (string, error) {
	return dag.Container().
		From("alpine:3.20").
		WithExec([]string{"apk", "add", "--no-cache", "curl", "jq"}).
		WithServiceBinding("grafana", grafana).
		WithDirectory("/src", src).
		WithWorkdir("/src").
		WithEnvVariable("GRAFANA_URL", "http://grafana:3000").
		WithEnvVariable("GRAFANA_USER", grafanaUser).
		WithSecretVariable("GRAFANA_PASSWORD", grafanaPassword).
		WithEnvVariable("CACHE_BUSTER", time.Now().String()).
		WithExec([]string{"sh", "scripts/configure-grafana.sh"}).
		Stdout(ctx)
}