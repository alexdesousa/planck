# Displaying Images in Planck

Planck agents can display images inline in the chat UI using standard Markdown image syntax. The web UI renders them via a built-in image proxy at `GET /api/proxy?url=...`.

## Markdown syntax

```markdown
![alt text](https://image.example.com/photo.png)
![local file](file:///home/user/comfyui/output/image.png)
```

The proxy rewrites these `src` attributes in the rendered HTML so that images are fetched through the Planck server rather than directly by the browser. This avoids mixed-content errors and lets you serve local files securely.

## Security model

The proxy uses a **deny-by-default allowlist**. Until you explicitly configure allowed sources, every proxy request returns `403 Forbidden`. This prevents agents from using the proxy to exfiltrate data or read arbitrary files.

Two allowlists are enforced separately:

- **`proxy_image_domains`** — HTTP/HTTPS domains an agent is allowed to proxy. Only exact host matches are accepted (no wildcards).
- **`proxy_image_paths`** — Local filesystem path prefixes from which files may be served. Paths are `Path.expand`-ed before comparison to prevent directory traversal (e.g. `../../etc/passwd` attacks).

## Configuration

Set environment variables before starting `planck`:

```sh
# Comma-separated; supports host:port
PLANCK_PROXY_IMAGE_DOMAINS=image.example.com,cdn.another.com:8080

# Colon-separated path prefixes
PLANCK_PROXY_IMAGE_PATHS=/home/user/comfyui/output:/tmp/planck-images
```

When both lists are empty (the default), no images can be proxied.

These are `planck_cli`-only settings and are **not** read from `config.json`.

## Example: ComfyUI output

If you run ComfyUI locally and want agents to display generated images:

```json
{
  "proxy_image_paths": ["/home/user/comfyui/output"]
}
```

An agent can then return:

```markdown
Here is the generated image:

![ComfyUI output](file:///home/user/comfyui/output/ComfyUI_12345.png)
```

The Planck web UI will render the image inline. Files outside `/home/user/comfyui/output` (e.g. `/home/user/comfyui/output/../../../etc/passwd`) are rejected with `403`.

