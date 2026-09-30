#!/usr/bin/env python3
"""Build a Clash configuration without editing YAML using regular expressions."""
import argparse
import json
from pathlib import Path

import yaml


def build(subscription, template, ports, secret):
    source = yaml.safe_load(subscription)
    if not isinstance(source, dict):
        raise ValueError("请使用 Clash YAML 订阅；节点链接列表和 Base64 订阅需要先转换。")
    proxies = source.get("proxies", [])
    providers = source.get("proxy-providers", {})
    if not isinstance(proxies, list) or not isinstance(providers, dict):
        raise ValueError("订阅中的 proxies / proxy-providers 格式不正确。")
    if not proxies and not providers:
        raise ValueError("订阅没有可用节点或节点提供者。")
    if template:
        config = yaml.safe_load(template)
        # A complete subscription may contain inline nodes, providers, or both.
        # Copy the nodes into the template instead of treating a full config as
        # a provider file, which loses provider-only subscriptions.
        config["proxy-providers"] = providers
        config["proxies"] = config.get("proxies", []) + proxies
    else:
        if not source.get("rules") and source.get("mode") != "global":
            raise ValueError("模板关闭时需要包含 rules 的完整 Clash 配置；仅节点订阅请开启内置规则模板。")
        config = source
    config.update(ports)
    config.update({"external-ui": "/opt/ui", "allow-lan": True, "secret": secret})
    return yaml.safe_dump(config, allow_unicode=True, sort_keys=False)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--subscription", required=True)
    parser.add_argument("--template")
    parser.add_argument("--output", required=True)
    parser.add_argument("--ports", required=True)
    parser.add_argument("--secret-file", required=True)
    args = parser.parse_args()
    try:
        result = build(
            Path(args.subscription).read_text(),
            Path(args.template).read_text() if args.template else None,
            json.loads(args.ports),
            json.loads(Path(args.secret_file).read_text())["secret"],
        )
        Path(args.output).write_text(result)
    except (OSError, ValueError, KeyError, yaml.YAMLError) as error:
        parser.exit(1, f"配置生成失败：{error}\n")


if __name__ == "__main__":
    main()
