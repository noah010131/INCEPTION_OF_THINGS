# Part 3

Debian 13 VM에서 Docker, k3d, Argo CD를 실행합니다. Argo CD는 GitHub의 `main` 브랜치에 있는 `p3/confs/app/`을 감시하고 Playground를 `dev` 네임스페이스에 배포합니다.

## 설치

`p3` 디렉터리에서 VM을 시작합니다.

```bash
vagrant up
vagrant ssh
```

Debian VM 안에서 실행합니다.

```bash
cd /vagrant
bash scripts/setup.sh
```

1. Docker, kubectl, k3d를 설치하고 Docker 접근 권한을 확인합니다.
2. `iot-p3` 클러스터를 생성하거나 재사용하고 `argocd`, `dev` 네임스페이스를 생성합니다.
3. Argo CD를 설치하고 구성 요소가 준비될 때까지 기다립니다.
4. GitHub 저장소 접근을 확인하고 Application을 생성한 뒤 `Synced`, `Healthy`, Playground 롤아웃을 확인합니다.

`--skip-install`은 도구 설치를 건너뜁니다. `--sync`는 기존 클러스터에서 Application 연결과 배포 확인만 실행합니다.

## Playground 확인

Debian VM에서 포트 포워딩을 실행합니다.

```bash
kubectl --context k3d-iot-p3 -n dev port-forward svc/playground-service 8888:80
```

VM의 다른 터미널에서 `curl http://127.0.0.1:8888/`로 응답을 확인합니다.

Bonus는 같은 클러스터에 GitLab Omnibus를 추가합니다. GitLab 프로젝트를 만든 뒤 Bonus의 `--sync`를 실행하면 기존 `playground` Application의 소스가 GitHub에서 GitLab으로 바뀝니다.
