#!/usr/bin/env python3
"""
List uncleaned (idle/empty) AWS Load Balancers from the last 24 hours.
Outputs: LB name and tenant name (parsed from DuploCloud naming convention).

Iterates over all non-interactive profiles in ~/.aws/config that use
duplo-jit credential_process. Interactive profiles are skipped automatically.

DuploCloud LB naming: duploservices-<tenant>-<service>
                  or: duplo-<tenant>-<service>

READ-ONLY — no LBs are modified or deleted.
Logs to console and to uncleaned_lbs.log in the current directory.
"""

import argparse
import boto3
import configparser
import datetime
import logging
import sys
from collections import defaultdict
from pathlib import Path

NOW = datetime.datetime.utcnow()
SINCE = NOW - datetime.timedelta(hours=24)
LOG_FILE = Path(__file__).parent / "uncleaned_lbs.log"
AWS_CONFIG = Path.home() / ".aws" / "config"
SKIP_PROFILES = {"duplo-prod", "gcp"}


def setup_logging():
    logger = logging.getLogger("uncleaned_lbs")
    logger.setLevel(logging.DEBUG)
    fmt = logging.Formatter(
        fmt="%(asctime)s [%(levelname)s] %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )
    console = logging.StreamHandler(sys.stdout)
    console.setLevel(logging.INFO)
    console.setFormatter(fmt)
    file_handler = logging.FileHandler(LOG_FILE)
    file_handler.setLevel(logging.DEBUG)
    file_handler.setFormatter(fmt)
    logger.addHandler(console)
    logger.addHandler(file_handler)
    return logger


log = setup_logging()


def load_profiles():
    """
    Read ~/.aws/config and return a list of (profile_name, region) tuples.
    Only includes duplo-jit profiles that have a --token (non-interactive).
    """
    config = configparser.ConfigParser()
    config.read(AWS_CONFIG)

    profiles = []
    for section in config.sections():
        # config sections are like "profile duplo-prod" or "default"
        name = section.removeprefix("profile ").strip()
        credential_process = config.get(section, "credential_process", fallback="")
        region = config.get(section, "region", fallback="us-east-1").strip()

        if not credential_process:
            continue  # raw key profiles — skip; they may be expired

        # Only include duplo-jit profiles with --token (non-interactive)
        if "duplo-jit" in credential_process and "--token" in credential_process:
            if name in SKIP_PROFILES:
                log.debug(f"Skipping excluded profile: {name}")
                continue
            profiles.append((name, region))
            log.debug(f"Profile loaded: {name} (region={region})")
        elif "duplo-jit" in credential_process and "--interactive" in credential_process:
            log.debug(f"Skipping interactive profile: {name}")
        else:
            log.debug(f"Skipping non-duplo profile: {name}")

    return profiles


def extract_tenant(lb_name):
    for prefix in ("duploservices-", "duplo-"):
        if lb_name.lower().startswith(prefix):
            rest = lb_name[len(prefix):]
            parts = rest.split("-")
            if parts:
                return parts[0]
    return "unknown"


def should_skip(lb_name):
    name = lb_name.lower()
    skip_keywords = ["master", "duplo-native", "duplomaster", "duplo-master", "old-", "-old", "legacy"]
    skip_tenants = ["default", "master", "admin"]

    for kw in skip_keywords:
        if kw in name:
            log.debug(f"Skipping {lb_name!r} — matched keyword '{kw}'")
            return True

    tenant = extract_tenant(lb_name).lower()
    if tenant in skip_tenants:
        log.debug(f"Skipping {lb_name!r} — protected tenant '{tenant}'")
        return True

    return False


def get_cloudwatch_metric_sum(cw, namespace, metric_name, dimensions, period=86400):
    try:
        resp = cw.get_metric_statistics(
            Namespace=namespace,
            MetricName=metric_name,
            Dimensions=dimensions,
            StartTime=SINCE,
            EndTime=NOW,
            Period=period,
            Statistics=["Sum"],
        )
        datapoints = resp.get("Datapoints", [])
        total = sum(d["Sum"] for d in datapoints) if datapoints else 0
        log.debug(f"CloudWatch {metric_name} {dimensions}: {total}")
        return total
    except Exception as e:
        log.warning(f"CloudWatch query failed ({metric_name}): {e}")
        return None


def check_alb_nlb(session, region, profile):
    log.debug(f"[{profile}/{region}] Checking ALB/NLB...")
    elbv2 = session.client("elbv2", region_name=region)
    cw = session.client("cloudwatch", region_name=region)
    results = []

    paginator = elbv2.get_paginator("describe_load_balancers")
    lbs = [lb for page in paginator.paginate() for lb in page["LoadBalancers"]]
    log.debug(f"[{profile}/{region}] Found {len(lbs)} ALB/NLB(s)")

    tg_paginator = elbv2.get_paginator("describe_target_groups")
    lb_to_tgs = defaultdict(list)
    for page in tg_paginator.paginate():
        for tg in page["TargetGroups"]:
            for lb_arn in tg.get("LoadBalancerArns", []):
                lb_to_tgs[lb_arn].append(tg["TargetGroupArn"])

    for lb in lbs:
        arn = lb["LoadBalancerArn"]
        name = lb["LoadBalancerName"]
        lb_type = lb["Type"]
        reason = None

        tg_arns = lb_to_tgs.get(arn, [])
        if not tg_arns:
            reason = "no target groups attached"
        else:
            all_empty = all(
                not elbv2.describe_target_health(TargetGroupArn=tg)
                            .get("TargetHealthDescriptions", [])
                for tg in tg_arns
            )
            if all_empty:
                reason = "all target groups are empty"

        if reason is None:
            lb_dim_value = arn.split("loadbalancer/")[-1]
            if lb_type == "application":
                traffic = get_cloudwatch_metric_sum(
                    cw, "AWS/ApplicationELB", "RequestCount",
                    [{"Name": "LoadBalancer", "Value": lb_dim_value}]
                )
            elif lb_type == "network":
                traffic = get_cloudwatch_metric_sum(
                    cw, "AWS/NetworkELB", "ActiveFlowCount",
                    [{"Name": "LoadBalancer", "Value": lb_dim_value}]
                )
            else:
                traffic = None

            if traffic == 0:
                reason = "zero traffic in last 24h"

        if reason is None:
            log.debug(f"[{profile}/{region}] {name} — OK")
            continue

        if should_skip(name) or extract_tenant(name) == "unknown":
            continue

        tenant = extract_tenant(name)
        log.info(f"[{profile}/{region}] UNCLEANED: {name} (tenant={tenant}) — {reason}")
        results.append({"name": name, "tenant": tenant, "profile": profile, "region": region})

    return results


def check_classic_elbs(session, region, profile):
    log.debug(f"[{profile}/{region}] Checking Classic ELBs...")
    elb = session.client("elb", region_name=region)
    cw = session.client("cloudwatch", region_name=region)
    results = []

    paginator = elb.get_paginator("describe_load_balancers")
    lbs = [lb for page in paginator.paginate() for lb in page["LoadBalancerDescriptions"]]
    log.debug(f"[{profile}/{region}] Found {len(lbs)} Classic ELB(s)")

    for lb in lbs:
        name = lb["LoadBalancerName"]
        reason = None

        instances = lb.get("Instances", [])
        if not instances:
            reason = "no instances registered"
        else:
            health = elb.describe_instance_health(LoadBalancerName=name)
            healthy = [i for i in health.get("InstanceStates", []) if i["State"] == "InService"]
            if not healthy:
                reason = f"0/{len(instances)} instances in service"

        if reason is None:
            traffic = get_cloudwatch_metric_sum(
                cw, "AWS/ELB", "RequestCount",
                [{"Name": "LoadBalancerName", "Value": name}]
            )
            if traffic == 0:
                reason = "zero traffic in last 24h"

        if reason is None:
            log.debug(f"[{profile}/{region}] {name} — OK")
            continue

        if should_skip(name) or extract_tenant(name) == "unknown":
            continue

        tenant = extract_tenant(name)
        log.info(f"[{profile}/{region}] UNCLEANED: {name} (tenant={tenant}) — {reason}")
        results.append({"name": name, "tenant": tenant, "profile": profile, "region": region})

    return results


def get_regions(session, home_region):
    try:
        ec2 = session.client("ec2", region_name=home_region)
        return [r["RegionName"] for r in ec2.describe_regions(
            Filters=[{"Name": "opt-in-status", "Values": ["opt-in-not-required", "opted-in"]}]
        )["Regions"]]
    except Exception as e:
        log.warning(f"Could not list regions, falling back to home region ({home_region}): {e}")
        return [home_region]


def main():
    parser = argparse.ArgumentParser(description="List uncleaned LBs (READ ONLY)")
    parser.add_argument("--profile", help="Scan a single AWS profile instead of all")
    args = parser.parse_args()

    log.info("=" * 60)
    log.info("Uncleaned LB scan started — READ ONLY")
    log.info(f"Time range: {SINCE.strftime('%Y-%m-%d %H:%M')} UTC -> {NOW.strftime('%Y-%m-%d %H:%M')} UTC")
    log.info(f"Log file: {LOG_FILE}")

    profiles = load_profiles()
    if not profiles:
        log.error(f"No non-interactive duplo-jit profiles found in {AWS_CONFIG}")
        sys.exit(1)

    if args.profile:
        profiles = [(p, r) for p, r in profiles if p == args.profile]
        if not profiles:
            log.error(f"Profile '{args.profile}' not found or is excluded/interactive.")
            sys.exit(1)

    log.info(f"Profiles to scan: {', '.join(p for p, _ in profiles)}")

    all_results = []
    profile_errors = []

    for profile_name, home_region in profiles:
        log.info(f"\n--- Profile: {profile_name} (home region: {home_region}) ---")
        try:
            session = boto3.Session(profile_name=profile_name)
            regions = get_regions(session, home_region)
            log.info(f"Scanning {len(regions)} region(s) for profile '{profile_name}'...")

            for region in regions:
                try:
                    all_results.extend(check_alb_nlb(session, region, profile_name))
                    all_results.extend(check_classic_elbs(session, region, profile_name))
                except Exception as e:
                    log.error(f"[{profile_name}/{region}] Failed: {e}", exc_info=True)
                    profile_errors.append(f"{profile_name}/{region}")

        except Exception as e:
            log.error(f"[{profile_name}] Could not create session: {e}", exc_info=True)
            profile_errors.append(profile_name)

    if profile_errors:
        log.warning(f"Errors in: {', '.join(profile_errors)}")

    if not all_results:
        log.info("\nNo uncleaned load balancers found.")
        return

    all_results.sort(key=lambda x: (x["profile"], x["tenant"], x["name"]))

    log.info("")
    log.info(f"{'LB NAME':<50} {'TENANT':<20} {'PROFILE':<20} {'REGION'}")
    log.info("-" * 105)
    for r in all_results:
        log.info(f"{r['name']:<50} {r['tenant']:<20} {r['profile']:<20} {r['region']}")

    log.info("")
    log.info(f"Total: {len(all_results)} uncleaned load balancer(s)")
    log.info("Scan complete.")


if __name__ == "__main__":
    main()
