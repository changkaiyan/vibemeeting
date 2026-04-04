import argparse
import asyncio
import ssl
from contextlib import suppress
from typing import Iterable
from urllib.parse import urlsplit

from aiohttp import ClientSession, ClientTimeout, WSMsgType, web


HOP_BY_HOP_HEADERS = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailer",
    "transfer-encoding",
    "upgrade",
}


def _filtered_headers(headers: Iterable[tuple[str, str]]) -> dict[str, str]:
    return {
        key: value
        for key, value in headers
        if key.lower() not in HOP_BY_HOP_HEADERS
    }


def _to_ws_scheme(url: str) -> str:
    parsed = urlsplit(url)
    if parsed.scheme == "https":
        scheme = "wss"
    else:
        scheme = "ws"
    return parsed._replace(scheme=scheme).geturl().rstrip("/")


def _join_upstream(upstream_base: str, request: web.Request) -> str:
    path_qs = request.rel_url.path_qs
    if path_qs.startswith("/"):
        return upstream_base + path_qs
    return f"{upstream_base}/{path_qs}"


async def _pipe_ws_to_client(
    upstream_ws,
    client_ws: web.WebSocketResponse,
) -> None:
    async for msg in upstream_ws:
        if msg.type == WSMsgType.TEXT:
            await client_ws.send_str(msg.data)
        elif msg.type == WSMsgType.BINARY:
            await client_ws.send_bytes(msg.data)
        elif msg.type == WSMsgType.PING:
            await client_ws.ping()
        elif msg.type == WSMsgType.PONG:
            await client_ws.pong()
        elif msg.type == WSMsgType.CLOSE:
            await client_ws.close()
            return


async def _pipe_client_to_ws(
    client_ws: web.WebSocketResponse,
    upstream_ws,
) -> None:
    async for msg in client_ws:
        if msg.type == WSMsgType.TEXT:
            await upstream_ws.send_str(msg.data)
        elif msg.type == WSMsgType.BINARY:
            await upstream_ws.send_bytes(msg.data)
        elif msg.type == WSMsgType.CLOSE:
            await upstream_ws.close()
            return


async def create_app(upstream_http: str) -> web.Application:
    session = ClientSession(timeout=ClientTimeout(total=None))
    upstream_http = upstream_http.rstrip("/")
    upstream_ws = _to_ws_scheme(upstream_http)

    async def handle(request: web.Request) -> web.StreamResponse:
        is_websocket = request.headers.get("Upgrade", "").lower() == "websocket"
        if is_websocket:
            ws_client = web.WebSocketResponse()
            await ws_client.prepare(request)

            ws_target = _join_upstream(upstream_ws, request)
            headers = _filtered_headers(request.headers.items())
            headers.pop("Host", None)

            async with session.ws_connect(
                ws_target,
                headers=headers,
                protocols=request.headers.getall("Sec-WebSocket-Protocol", []),
                autoping=False,
            ) as ws_upstream:
                tasks = [
                    asyncio.create_task(_pipe_client_to_ws(ws_client, ws_upstream)),
                    asyncio.create_task(_pipe_ws_to_client(ws_upstream, ws_client)),
                ]
                done, pending = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
                for task in pending:
                    task.cancel()
                for task in done:
                    with suppress(asyncio.CancelledError):
                        task.result()
            return ws_client

        target = _join_upstream(upstream_http, request)
        body = await request.read()
        headers = _filtered_headers(request.headers.items())
        headers.pop("Host", None)
        headers["X-Forwarded-Proto"] = "https"
        headers["X-Forwarded-Host"] = request.host

        async with session.request(
            request.method,
            target,
            data=body if body else None,
            headers=headers,
            allow_redirects=False,
        ) as upstream_response:
            response_body = await upstream_response.read()
            response_headers = _filtered_headers(upstream_response.headers.items())
            return web.Response(
                status=upstream_response.status,
                headers=response_headers,
                body=response_body,
            )

    async def close_session(_app: web.Application) -> None:
        await session.close()

    app = web.Application()
    app.add_routes([web.route("*", "/{tail:.*}", handle)])
    app.on_cleanup.append(close_session)
    return app


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="TLS reverse proxy for LiveKit (HTTP+WebSocket).",
    )
    parser.add_argument("--listen-host", default="0.0.0.0")
    parser.add_argument("--listen-port", type=int, default=7443)
    parser.add_argument("--upstream", default="http://127.0.0.1:7880")
    parser.add_argument("--cert-file", required=True)
    parser.add_argument("--key-file", required=True)
    return parser.parse_args()


async def main() -> None:
    args = parse_args()
    app = await create_app(args.upstream)
    ssl_ctx = ssl.create_default_context(ssl.Purpose.CLIENT_AUTH)
    ssl_ctx.load_cert_chain(args.cert_file, args.key_file)
    runner = web.AppRunner(app)
    await runner.setup()
    site = web.TCPSite(
        runner,
        host=args.listen_host,
        port=args.listen_port,
        ssl_context=ssl_ctx,
    )
    await site.start()
    print(
        f"LiveKit TLS proxy listening on https://{args.listen_host}:{args.listen_port} "
        f"-> {args.upstream}",
        flush=True,
    )
    while True:
        await asyncio.sleep(3600)


if __name__ == "__main__":
    asyncio.run(main())
