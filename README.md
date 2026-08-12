# hermes-agent

Docker Compose deployment cho [Hermes Agent](https://hub.docker.com/r/nousresearch/hermes-agent).

Image là **stateless** — toàn bộ state (config, API keys, sessions, memories, skills, logs)
nằm ở `/opt/data` trong container, mount từ `~/.hermes` trên host. Nâng cấp = pull image mới,
không mất gì.

---

## Cài nhanh

```bash
git clone git@github-0xphuong:0xphuong/hermes-agent.git
cd hermes-agent
./setup.sh
```

Script tạo thư mục dữ liệu, chạy setup wizard của hermes, `docker compose up -d`, rồi in ra URL
và thông tin truy cập. Chạy lại nhiều lần được — giá trị đã có không bị ghi đè.

**Secret nội bộ** (`HERMES_DASHBOARD_SECRET`, `JWT_SECRET`, `API_KEY_SECRET`, `MACHINE_ID_SALT`)
sinh tự động, không hỏi.

**Mật khẩu đăng nhập** — dashboard và 9router — script hỏi bạn nhập (gõ 2 lần, không hiện ký tự).
Nhấn Enter để bỏ qua và dùng chuỗi ngẫu nhiên.

> Mật khẩu không được chứa `$`. Docker compose hiểu đó là biến và nuốt phần sau — `ab$cde` vào
> container chỉ còn `ab`, không báo lỗi gì. Script chặn ngay lúc nhập.

| Tuỳ chọn | Tác dụng |
|---|---|
| `--with-claude-code` | Build image từ `Dockerfile` (có sẵn CLI `claude`) thay vì dùng image chính thức |
| `--no-start` | Chỉ tạo file config, không khởi động |
| `--non-interactive` | Không hỏi gì, sinh ngẫu nhiên cả mật khẩu đăng nhập (dùng cho CI) |
| `--help` | Xem hướng dẫn |

Phần dưới mô tả các bước thủ công mà script làm thay.

---

## Cài lần đầu (thủ công)

### 1. Chuẩn bị

```bash
git clone git@github-0xphuong:0xphuong/hermes-agent.git
cd hermes-agent
cp .env.example .env
```

Sinh 2 secret và điền vào `.env`:

```bash
openssl rand -hex 32   # -> HERMES_DASHBOARD_PASSWORD
openssl rand -hex 32   # -> HERMES_DASHBOARD_SECRET
```

### 2. Chạy setup wizard

Wizard hỏi API key của model và token các chat platform, ghi vào `~/.hermes/.env`.
Chỉ cần làm **một lần**:

```bash
mkdir -p ~/.hermes
docker run -it --rm -v ~/.hermes:/opt/data nousresearch/hermes-agent setup
```

> **Đừng dùng browser console của VPS** (Hetzner và nhiều nhà cung cấp khác) để gõ lệnh này.
> Console web truyền sai ký tự đặc biệt — `:` thành `;`, `@` lỗi render — làm hỏng ngầm tham số
> `-v ~/.hermes:/opt/data` và API key dán vào. Dùng SSH: `ssh root@<host>`.

Nếu dùng Nous Portal, chạy thêm (refresh token persist trong volume):

```bash
docker run -it --rm -v ~/.hermes:/opt/data nousresearch/hermes-agent setup --portal
```

### 3. Khởi động

```bash
docker compose up -d
docker compose logs -f
```

---

## Truy cập

| Dịch vụ | Địa chỉ | Ghi chú |
|---|---|---|
| Dashboard | `http://127.0.0.1:9119` | Đăng nhập bằng `HERMES_DASHBOARD_USER` / `_PASSWORD` |
| API (OpenAI-compatible) | `http://127.0.0.1:8642` | Chỉ hoạt động khi bật `API_SERVER_*` |

Mặc định **cả hai chỉ bind vào loopback của host**. Vào dashboard từ máy khác qua SSH tunnel:

```bash
ssh -L 9119:127.0.0.1:9119 user@host
# rồi mở http://127.0.0.1:9119 trên máy local
```

### Nếu muốn phơi ra ngoài

Đổi `HERMES_BIND_ADDR=0.0.0.0` trong `.env`. Trước khi làm, hiểu rõ:

Dashboard public **không auth** chính là điểm xâm nhập của chiến dịch MCP-config persistence
tháng 6/2026 — scanner internet tìm thấy dashboard phơi ra và điều khiển agent cắm SSH-key
backdoor. Compose này đã cấu hình sẵn basic auth nên gate luôn bật, nhưng basic auth
**không đủ** cho internet công cộng. Với public deploy, dùng OAuth (Nous Portal:
`HERMES_DASHBOARD_OAUTH_CLIENT_ID`) hoặc self-hosted OIDC (`HERMES_DASHBOARD_OIDC_ISSUER` +
`_CLIENT_ID`), hoặc để nguyên loopback và đi qua VPN/Tailscale.

`HERMES_DASHBOARD_INSECURE` đã bị vô hiệu hoá — không còn cách nào tắt auth trên bind
non-loopback.

---

## Vận hành hằng ngày

```bash
docker compose logs -f                    # log realtime (gateway + dashboard)
docker compose restart                    # restart cả container
docker compose ps                         # trạng thái

docker exec hermes hermes logs --follow   # log Hermes có cấu trúc
docker exec hermes hermes status          # báo "Manager: s6 (container supervisor)"
docker exec -it hermes hermes             # mở CLI chat trong container đang chạy
```

`docker exec hermes ...` tự động drop từ root xuống user `hermes` (UID 10000) nên file
sinh ra có đúng quyền — không cần `--user`.

### Log nằm ở đâu

| Nguồn | Vị trí |
|---|---|
| Gateway + dashboard, realtime | `docker compose logs -f` (xoay vòng 20MB × 5, mất khi `docker rm`) |
| Gateway, bản bền theo profile | `~/.hermes/logs/gateways/<profile>/current` (rotated 10 × 1MB) |
| Audit khởi động container | `~/.hermes/logs/container-boot.log` |
| `agent.log`, `errors.log` | `~/.hermes/logs/` |

Chỉ file trên volume sống sót qua `docker rm`.

---

## Multi-profile

Một container chạy được nhiều profile độc lập (SOUL, skills, memory, sessions riêng).
Mỗi profile là một s6 service được giám sát, tự restart khi crash — **không cần thêm container**:

```bash
docker exec hermes hermes profile create coder
docker exec hermes hermes -p coder gateway start
docker exec hermes hermes -p coder gateway status
docker exec hermes hermes profile delete coder
```

Gateway đang chạy sẽ **tự bật lại** sau `docker compose restart` hoặc nâng cấp image.
Chỉ khi bạn chủ động `hermes gateway stop` thì nó mới nằm im qua restart.

**Dashboard chỉ cần một port cho mọi profile** — profile switcher trong UI gửi kèm profile đích.

**Client OpenAI-compatible thì khác:** mỗi profile có API server riêng và đều mặc định bind
8642 → đụng nhau. Cấp port riêng trong `.env` *của chính profile đó*:

```bash
docker exec hermes hermes profile create work
cat >> ~/.hermes/profiles/work/.env <<'EOF'
API_SERVER_ENABLED=true
API_SERVER_PORT=8643
EOF
docker exec hermes hermes -p work gateway restart
```

Rồi publish thêm `- "127.0.0.1:8643:8643"` trong `docker-compose.yml`.

> Đừng bao giờ đặt `API_SERVER_PORT` trong khối `environment:` của compose — giá trị global
> sẽ ép mọi profile về cùng một port.

---

## Nâng cấp

```bash
docker compose pull
docker compose up -d
```

Data dir giữ nguyên. Container tự chạy config-schema migration và ghi backup có timestamp
cạnh `config.yaml` / `.env` trước khi sửa. Muốn tự kiểm tra trước thì thêm
`HERMES_SKIP_CONFIG_MIGRATION=1` vào `environment:`.

Ở production nên pin `HERMES_IMAGE_TAG` về version cụ thể thay vì `latest`.

---

## Backup

Toàn bộ state nằm ở một thư mục:

```bash
docker compose stop
tar czf hermes-backup-$(date +%F).tar.gz -C ~ .hermes
docker compose start
```

---

## Cấu hình thêm

`config.yaml` nằm ở `~/.hermes/config.yaml`.

### Chặn tool-loop cho gateway không người trực

Mặc định Hermes chỉ cảnh báo khi agent kẹt trong vòng lặp gọi tool — hợp lý cho CLI có người
ngồi xem, nhưng với gateway chạy nền thì cảnh báo không dừng được gì. Bật circuit-breaker:

```yaml
tool_loop_guardrails:
  hard_stop_enabled: true
  hard_stop_after:
    exact_failure: 5
    idempotent_no_progress: 5
```

### Trỏ vào inference server local (vLLM / Ollama)

Server chạy trên **chính host này** (Linux):

```yaml
model:
  provider: custom
  model: my-model
  base_url: http://172.17.0.1:8000/v1   # docker0 gateway; hoặc host.docker.internal trên macOS
  api_key: "none"
```

Server chạy trong **container khác**: cho cả hai vào chung network rồi dùng **tên container**
làm hostname (`http://vllm:8000/v1`) — không dùng `localhost`, đó là chính container Hermes.
Không có dấu `/` cuối `base_url`. `model` phải khớp `--served-model-name`.

Kiểm tra: `docker exec hermes curl -s http://vllm:8000/v1/models`

---

## Cài thêm tool vào container

`/opt/hermes` là install tree **bất biến**, read-only với runtime. Mọi thứ mutable thuộc về
`/opt/data`.

- **npm / PyPI** → bảo Hermes chạy qua `npx` / `uvx` và ghi nhớ lệnh vào memory. Config đặt
  dưới `/opt/data/<tool>/`.
- **apt package / binary** → dạy Hermes lệnh cài, bảo nó nhớ. Tồn tại hết đời container.
- **Cần có sẵn mỗi lần start** → build image dẫn xuất `FROM nousresearch/hermes-agent:latest`,
  `USER root` → cài → `USER hermes`. Rồi đổi `image:` trong compose.
- **Tool kèm service riêng** (DB, queue) → chạy sidecar cùng network, gọi qua tên container.

Skill CLI lưu credential dưới `~` phải init đúng HOME của subprocess. Ví dụ `xurl`:

```bash
docker exec -it hermes env HOME=/opt/data/home xurl auth
docker exec hermes env HOME=/opt/data/home xurl auth status
```

---

## Troubleshooting

| Triệu chứng | Xử lý |
|---|---|
| Compose báo `required variable ... is missing` | Chưa `cp .env.example .env` hoặc chưa điền credential dashboard |
| Container exit ngay | `docker compose logs` — thường do chưa chạy `setup`, hoặc trùng port |
| `Permission denied` trên `~/.hermes` | Runtime chạy UID 10000. Đặt `HERMES_PUID`/`HERMES_PGID` khớp chủ thư mục (`id -u`, `id -g`) |
| Browser tools chết lặng | Thiếu shared memory — compose đã set `shm_size: 1gb`, kiểm tra chưa bị override |
| Dashboard không vào được | Đang bind loopback (đúng thiết kế) — dùng SSH tunnel |
| Gateway kẹt sau sự cố mạng | `docker compose restart` |

Kiểm tra version image: `docker run --rm nousresearch/hermes-agent:latest version`

---

## Cảnh báo

**Không bao giờ chạy hai container Hermes trỏ vào cùng một data directory.** Session files và
memory store không hỗ trợ ghi đồng thời — sẽ hỏng dữ liệu.

**Không commit `.env`.** Đã có trong `.gitignore`.
