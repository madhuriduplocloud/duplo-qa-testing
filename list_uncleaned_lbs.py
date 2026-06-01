#!/usr/bin/env python3
"""
List uncleaned AWS Load Balancers created more than 10 hours ago.
Outputs: LB name, tenant name, age, profile, region.

Iterates over all non-interactive profiles in ~/.aws/config that use
duplo-jit credential_process. Interactive profiles are skipped automatically.

DuploCloud LB naming: duploservices-<tenant>-<service>
                  or: duplo2-<tenant>-<service>
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
from pathlib import Path

NOW = datetime.datetime.now(datetime.timezone.utc)
AGE_THRESHOLD_HOURS = 10
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
    config = configparser.ConfigParser()
    config.read(AWS_CONFIG)
    profiles = []
    for section in config.sections():
        name = section.removeprefix("profile ").strip()
        credential_process = config.get(section, "credential_process", fallback="")
        region = config.get(section, "region", fallback="us-east-1").strip()
        if not credential_process:
            continue
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
    for prefix in ("duploservices-", "duplo2-", "duplo-"):
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


def age_str(created_time):
    delta = NOW - created_time
    hours = int(delta.total_seconds() // 3600)
    minutes = int((delta.total_seconds() % 3600) // 60)
    return f"{hours}h {minutes}m"


def check_alb_nlb(session, region, profile, min_age_hours=AGE_THRESHOLD_HOURS):
    log.debug(f"[{profile}/{region}] Checking ALB/NLB...")
    elbv2 = session.client("elbv2", region_name=region)
    results = []

    paginator = elbv2.get_paginator("describe_load_balancers")
    lbs = [lb for page in paginator.paginate() for lb in page["LoadBalancers"]]
    log.debug(f"[{profile}/{region}] Found {len(lbs)} ALB/NLB(s)")

    for lb in lbs:
        name = lb["LoadBalancerName"]
        created = lb.get("CreatedTime")
        if not created:
            continue

        age_hours = (NOW - created).total_seconds() / 3600
        if age_hours < min_age_hours:
            log.debug(f"[{profile}/{region}] {name} — too new ({age_str(created)}), skipping")
            continue

        if should_skip(name) or extract_tenant(name) == "unknown":
            continue

        tenant = extract_tenant(name)
        log.info(f"[{profile}/{region}] UNCLEANED: {name} (tenant={tenant}, age={age_str(created)})")
        results.append({
            "name": name,
            "tenant": tenant,
            "age": age_str(created),
            "profile": profile,
            "region": region,
        })

    return results


def check_classic_elbs(session, region, profile, min_age_hours=AGE_THRESHOLD_HOURS):
    log.debug(f"[{profile}/{region}] Checking Classic ELBs...")
    elb = session.client("elb", region_name=region)
    results = []

    paginator = elb.get_paginator("describe_load_balancers")
    lbs = [lb for page in paginator.paginate() for lb in page["LoadBalancerDescriptions"]]
    log.debug(f"[{profile}/{region}] Found {len(lbs)} Classic ELB(s)")

    for lb in lbs:
        name = lb["LoadBalancerName"]
        created = lb.get("CreatedTime")
        if not created:
            continue

        age_hours = (NOW - created).total_seconds() / 3600
        if age_hours < min_age_hours:
            log.debug(f"[{profile}/{region}] {name} — too new ({age_str(created)}), skipping")
            continue

        if should_skip(name) or extract_tenant(name) == "unknown":
            continue

        tenant = extract_tenant(name)
        log.info(f"[{profile}/{region}] UNCLEANED: {name} (tenant={tenant}, age={age_str(created)})")
        results.append({
            "name": name,
            "tenant": tenant,
            "age": age_str(created),
            "profile": profile,
            "region": region,
        })

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
    parser = argparse.ArgumentParser(description="List uncleaned LBs older than N hours (READ ONLY)")
    parser.add_argument("--profile", help="Scan a single AWS profile instead of all")
    parser.add_argument("--min-age-hours", type=int, default=AGE_THRESHOLD_HOURS,
                        help=f"Minimum LB age in hours to report (default: {AGE_THRESHOLD_HOURS})")
    args = parser.parse_args()
    min_age_hours = args.min_age_hours

    log.info("=" * 60)
    log.info(f"Uncleaned LB scan started — LBs older than {min_age_hours}h — READ ONLY")
    log.info(f"Current time: {NOW.strftime('%Y-%m-%d %H:%M')} UTC")
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
                    all_results.extend(check_alb_nlb(session, region, profile_name, min_age_hours))
                    all_results.extend(check_classic_elbs(session, region, profile_name, min_age_hours))
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
    log.info(f"{'LB NAME':<50} {'TENANT':<20} {'AGE':<12} {'PROFILE':<20} {'REGION'}")
    log.info("-" * 115)
    for r in all_results:
        log.info(f"{r['name']:<50} {r['tenant']:<20} {r['age']:<12} {r['profile']:<20} {r['region']}")

    log.info("")
    log.info(f"Total: {len(all_results)} uncleaned load balancer(s)")
    log.info("Scan complete.")


if __name__ == "__main__":
    main()
