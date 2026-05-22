
![License](https://img.shields.io/badge/License-MIT-green)
![Platform](https://img.shields.io/badge/Platform-Ubuntu-orange)
![DevOps](https://img.shields.io/badge/DevOps-Ready-blue)
![Automation](https://img.shields.io/badge/Automation-Enabled-blue)


# Nexoryx_Airflow

Production-ready automated Apache Airflow 3.2.1 deployment for Ubuntu 24.04 EC2 with PostgreSQL, Redis/CeleryExecutor, Nginx, HTTPS, Azure Entra ID SSO, and API DAG triggering.

---

# Features

- Apache Airflow 3.2.1
- PostgreSQL Backend
- Redis + CeleryExecutor
- Nginx Reverse Proxy
- HTTPS using Certbot
- Azure Entra ID SSO
- API DAG Triggering
- Automatic systemd service creation
- Ubuntu 24.04 EC2 automation

---

# Architecture

EC2 Ubuntu 24.04
    |
    +-- Airflow API Server
    +-- Scheduler
    +-- DAG Processor
    +-- Triggerer
    +-- Celery Worker
    |
    +-- PostgreSQL
    +-- Redis
    +-- Nginx
    +-- HTTPS
    +-- Azure Entra ID SSO

---

# Installation

## Clone Repository

```bash
git clone https://github.com/bkarankar/Nexoryx_Airflow3.git

cd Nexoryx_Airflow
```

## Run Installer

```bash
chmod +x install_airflow3_ec2.sh

sudo bash install_airflow3_ec2.sh
```

---

# Security Notice

The Azure Entra ID values used in this repository are dummy/sample placeholders only.

You MUST replace them with your own valid Azure Entra ID application details before deployment.

Example:

```bash
AZURE_TENANT_ID="your-real-tenant-id"
AZURE_CLIENT_ID="your-real-client-id"
AZURE_CLIENT_SECRET="your-real-client-secret"
```

Never commit real production secrets to GitHub repositories.

---

# Dummy Azure Variables

```bash
AZURE_TENANT_ID="${AZURE_TENANT_ID:-00000000-0000-0000-0000-000000000000}"
AZURE_CLIENT_ID="${AZURE_CLIENT_ID:-11111111-1111-1111-1111-111111111111}"
AZURE_CLIENT_SECRET="${AZURE_CLIENT_SECRET:-dummy-client-secret-example}"
```

These are NOT real production credentials.

---

# Stack

- Apache Airflow 3.2.1
- PostgreSQL
- Redis
- CeleryExecutor
- Nginx
- Certbot
- Azure Entra ID SSO
- Ubuntu 24.04
- EC2

---

# License

MIT License


---

# GitHub Actions Included

This repository includes automated GitHub Actions workflows for:

- Terraform validation
- Shell script validation using ShellCheck
- Markdown linting

Workflow files:

```text
.github/workflows/
```


## Project Roadmap

- [ ] Kubernetes Helm charts
- [ ] GitOps support
- [ ] CI/CD improvements
- [ ] Monitoring dashboards
- [ ] Multi-cloud support
- [ ] Security hardening

## GitHub Actions

This repository includes:
- Shell validation
- Markdown linting
- Terraform validation (where applicable)

## Example Deployments

See:
- examples/
- docs/

## Related Nexoryx Projects

This repository is part of the Nexoryx infrastructure ecosystem.
