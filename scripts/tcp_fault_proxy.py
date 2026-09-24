#!/usr/bin/env python3
"""A loopback TCP proxy whose control socket can sever live connections.

The iOS walkthrough uses this between the shipped SSH client and a disposable
OpenSSH server.  Sending ``drop\n`` to the control port aborts both sides of
every active stream without stopping the listener, so the app sees a real TCP
loss and can reconnect to the same endpoint immediately afterwards.
"""

import argparse
import asyncio


class FaultProxy:
    def __init__(self, target_host: str, target_port: int):
        self.target_host = target_host
        self.target_port = target_port
        self.active: set[asyncio.StreamWriter] = set()

    async def proxy(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
        try:
            upstream_reader, upstream_writer = await asyncio.open_connection(
                self.target_host, self.target_port
            )
        except OSError:
            writer.close()
            await writer.wait_closed()
            return

        self.active.update((writer, upstream_writer))

        async def copy(source: asyncio.StreamReader, destination: asyncio.StreamWriter):
            while data := await source.read(64 * 1024):
                destination.write(data)
                await destination.drain()

        forward = asyncio.create_task(copy(reader, upstream_writer))
        reverse = asyncio.create_task(copy(upstream_reader, writer))
        try:
            _, pending = await asyncio.wait(
                (forward, reverse), return_when=asyncio.FIRST_COMPLETED
            )
            for task in pending:
                task.cancel()
            await asyncio.gather(*pending, return_exceptions=True)
        finally:
            self.active.difference_update((writer, upstream_writer))
            for stream in (writer, upstream_writer):
                stream.close()
            await asyncio.gather(
                writer.wait_closed(), upstream_writer.wait_closed(),
                return_exceptions=True,
            )

    async def control(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
        command = (await reader.readline()).strip().lower()
        if command == b"drop":
            streams = list(self.active)
            for stream in streams:
                transport = stream.transport
                if transport is not None:
                    transport.abort()
            writer.write(f"OK {len(streams) // 2}\n".encode())
        else:
            writer.write(b"ERROR expected drop\n")
        await writer.drain()
        writer.close()
        await writer.wait_closed()


async def run(args):
    proxy = FaultProxy(args.target_host, args.target_port)
    data_server = await asyncio.start_server(proxy.proxy, args.listen_host, args.listen_port)
    control_server = await asyncio.start_server(
        proxy.control, args.listen_host, args.control_port
    )
    async with data_server, control_server:
        await asyncio.gather(
            data_server.serve_forever(), control_server.serve_forever()
        )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--listen-host", default="127.0.0.1")
    parser.add_argument("--listen-port", type=int, required=True)
    parser.add_argument("--control-port", type=int, required=True)
    parser.add_argument("--target-host", default="127.0.0.1")
    parser.add_argument("--target-port", type=int, required=True)
    asyncio.run(run(parser.parse_args()))


if __name__ == "__main__":
    main()
