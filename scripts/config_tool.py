#!/usr/bin/env python3
"""Build a Clash configuration without editing YAML using regular expressions."""
import argparse
import json
from pathlib import Path

import yaml


def proxy_authentication(settings):
    username = settings.get("proxyUsername", "")
    password = settings.get("proxyPassword", "")
    if not isinstance(username, str) or not isinstance(password, str):
        raise ValueError("代理用户名和密码必须是文本。")
    if bool(username) != bool(password):
        raise ValueError("请同时填写代理用户名和密码，或同时留空。")
    if ":" in username or any(c in username + password for c in "\r\n\0"):
        raise ValueError("代理用户名不能包含冒号，用户名和密码不能包含换行或空字符。")
    if any(len(value.encode('utf-8')) > 255 for value in (username, password)):
        raise ValueError("代理用户名或密码过长，UTF-8 编码后不能超过 255 字节。")
    return [f"{username}:{password}"] if username else []


def validate_settings(settings):
    if not isinstance(settings, dict):
        raise ValueError("设置格式无效。")
    minutes = settings.get("intervalMinutes")
    if (type(settings.get("autoEnabled")) is not bool or
            type(settings.get("builtinEnabled")) is not bool or
            type(minutes) not in (int, float) or not 0 <= minutes <= 10080 or
            (settings["autoEnabled"] and minutes < 1)):
        raise ValueError("更新间隔或设置格式无效。")
    proxy_authentication(settings)


def build(subscription, template, ports, secret, settings=None):
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
    # Preserve existing subscription authentication until the user explicitly
    # configures these fields. Once saved, Portal controls it across updates.
    if settings is not None and ("proxyUsername" in settings or "proxyPassword" in settings):
        config["authentication"] = proxy_authentication(settings)
        config["skip-auth-prefixes"] = []
    return yaml.safe_dump(config, allow_unicode=True, sort_keys=False)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--subscription")
    parser.add_argument("--template")
    parser.add_argument("--output")
    parser.add_argument("--ports")
    parser.add_argument("--secret-file")
    parser.add_argument("--settings-file")
    parser.add_argument("--validate-settings")
    args = parser.parse_args()
    try:
        if args.validate_settings:
            validate_settings(json.loads(Path(args.validate_settings).read_text()))
            return
        if not all((args.subscription, args.output, args.ports, args.secret_file)):
            parser.error("配置生成需要 subscription、output、ports 和 secret-file")
        result = build(
            Path(args.subscription).read_text(),
            Path(args.template).read_text() if args.template else None,
            json.loads(args.ports),
            json.loads(Path(args.secret_file).read_text())["secret"],
            json.loads(Path(args.settings_file).read_text()) if args.settings_file else None,
        )
        Path(args.output).write_text(result)
    except (OSError, ValueError, KeyError, yaml.YAMLError) as error:
        parser.exit(1, f"配置生成失败：{error}\n")


if __name__ == "__main__":
    main()
