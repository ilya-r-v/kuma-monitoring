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

// DeployApp разворачивает слой приложения: Galera-кластер MariaDB (3 ноды) + HAProxy + Uptime Kuma.
func (m *KumaMonitoring) DeployApp(
	ctx context.Context,
	// +defaultPath="/"
	// +ignore=[".git", "**/.env", ".dagger"]
	src *dagger.Directory,
	sock *dagger.Socket,
	dbRootPassword *dagger.Secret,
	dbPassword *dagger.Secret,
	exporterPassword *dagger.Secret,
	// пароль пользователя для SST (передача данных новой ноде Galera)
	sstPassword *dagger.Secret,
) (string, error) {
	return dockerCli(src, sock).
		WithSecretVariable("DB_ROOT_PASSWORD", dbRootPassword).
		WithSecretVariable("DB_PASSWORD", dbPassword).
		WithSecretVariable("EXP_PW", exporterPassword).
		WithSecretVariable("SST_PASSWORD", sstPassword).
		// fail fast: с пустым паролем compose пересоздал бы контейнеры с неверным окружением
		WithExec([]string{"sh", "-c",
			`test -n "$DB_ROOT_PASSWORD" && test -n "$DB_PASSWORD" && test -n "$EXP_PW" && test -n "$SST_PASSWORD" || { echo "ERROR: empty password secret"; exit 1; }`}).
		WithExec([]string{"sh", "-c", ensureNetwork}).
		WithExec([]string{"docker", "compose", "-f", "app/compose.yml", "up", "-d", "--build", "--wait", "--remove-orphans"}).
		WithExec([]string{"sh", "scripts/create-exporter-user.sh"}).
		WithExec([]string{"docker", "compose", "-f", "app/compose.yml", "ps"}).
		Stdout(ctx)
}

// DeployMonitoring разворачивает слой мониторинга: Prometheus, Grafana и экспортеры.
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
		WithExec([]string{"sh", "-c",
			`test -n "$GRAFANA_ADMIN_PASSWORD" && test -n "$EXPORTER_DB_PASSWORD" || { echo "ERROR: empty password secret"; exit 1; }`}).
		WithExec([]string{"sh", "-c", ensureNetwork}).
		WithExec([]string{"docker", "compose", "-f", "monitoring/compose.yml", "up", "-d", "--build", "--wait", "--remove-orphans"}).
		WithExec([]string{"docker", "compose", "-f", "monitoring/compose.yml", "ps"}).
		Stdout(ctx)
}

// ConfigureGrafana настраивает datasource и дашборды через HTTP API Grafana (идемпотентно).
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

// toolbox — alpine с curl и jq для работы с HTTP API.
func toolbox(src *dagger.Directory) *dagger.Container {
	return dag.Container().
		From("alpine:3.20").
		WithExec([]string{"apk", "add", "--no-cache", "curl", "jq"}).
		WithDirectory("/src", src).
		WithWorkdir("/src").
		WithEnvVariable("CACHE_BUSTER", time.Now().String())
}

// Validate проверяет, что весь контур работает.
func (m *KumaMonitoring) Validate(
	ctx context.Context,
	// +defaultPath="/"
	// +ignore=[".git", "**/.env", ".dagger"]
	src *dagger.Directory,
	prometheus *dagger.Service,
	grafana *dagger.Service,
	grafanaPassword *dagger.Secret,
	// +optional
	// +default="admin"
	grafanaUser string,
) (string, error) {
	return toolbox(src).
		WithServiceBinding("prometheus", prometheus).
		WithServiceBinding("grafana", grafana).
		WithEnvVariable("PROMETHEUS_URL", "http://prometheus:9090").
		WithEnvVariable("GRAFANA_URL", "http://grafana:3000").
		WithEnvVariable("GRAFANA_USER", grafanaUser).
		WithSecretVariable("GRAFANA_PASSWORD", grafanaPassword).
		WithExec([]string{"sh", "scripts/validate.sh"}).
		Stdout(ctx)
}

// DeployAll разворачивает весь контур и проверяет его.
func (m *KumaMonitoring) DeployAll(
	ctx context.Context,
	// +defaultPath="/"
	// +ignore=[".git", "**/.env", ".dagger"]
	src *dagger.Directory,
	sock *dagger.Socket,
	prometheus *dagger.Service,
	grafana *dagger.Service,
	dbRootPassword *dagger.Secret,
	dbPassword *dagger.Secret,
	exporterPassword *dagger.Secret,
	grafanaPassword *dagger.Secret,
	sstPassword *dagger.Secret,
) (string, error) {
	out := ""

	s, err := m.DeployApp(ctx, src, sock, dbRootPassword, dbPassword, exporterPassword, sstPassword)
	if err != nil {
		return out, err
	}
	out += "=== deploy-app ===\n" + s

	s, err = m.DeployMonitoring(ctx, src, sock, grafanaPassword, exporterPassword)
	if err != nil {
		return out, err
	}
	out += "\n=== deploy-monitoring ===\n" + s

	s, err = m.ConfigureGrafana(ctx, src, grafana, grafanaPassword, "admin")
	if err != nil {
		return out, err
	}
	out += "\n=== configure-grafana ===\n" + s

	s, err = m.Validate(ctx, src, prometheus, grafana, grafanaPassword, "admin")
	if err != nil {
		return out, err
	}
	out += "\n=== validate ===\n" + s

	return out, nil
}

// Chaos роняет контейнер (SIGKILL) и проверяет обнаружение и автовосстановление.
func (m *KumaMonitoring) Chaos(
	ctx context.Context,
	// +defaultPath="/"
	// +ignore=[".git", "**/.env", ".dagger"]
	src *dagger.Directory,
	sock *dagger.Socket,
	prometheus *dagger.Service,
	// galera-1, galera-2, galera-3 или uptime-kuma
	// +optional
	// +default="galera-1"
	target string,
) (string, error) {
	return dockerCli(src, sock).
		WithExec([]string{"apk", "add", "--no-cache", "curl", "jq"}).
		WithServiceBinding("prometheus", prometheus).
		WithEnvVariable("PROMETHEUS_URL", "http://prometheus:9090").
		WithEnvVariable("TARGET", target).
		WithExec([]string{"sh", "scripts/chaos.sh"}).
		Stdout(ctx)
}