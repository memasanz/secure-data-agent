"""Generate a small synthetic retail-sales dataset for the Fabric Lakehouse demo.

Stdlib only (no external deps). Writes three CSVs into ./data/out:
  - customers.csv  (dim)
  - products.csv   (dim)
  - sales.csv      (fact, references customer_id + product_id)

The data is deterministic (fixed seed) so re-runs produce the same rows.
"""
import csv
import os
import random
from datetime import date, timedelta

SEED = 42
N_CUSTOMERS = 200
N_PRODUCTS = 60
N_SALES = 5000
START_DATE = date(2024, 1, 1)
END_DATE = date(2025, 12, 31)

OUT_DIR = os.path.join(os.path.dirname(__file__), "out")

REGIONS = ["West", "East", "Central", "South", "Northwest"]
SEGMENTS = ["Consumer", "Corporate", "Home Office"]
CHANNELS = ["Online", "In-Store", "Partner"]
CATEGORIES = {
    "Electronics": ["Headphones", "Monitor", "Keyboard", "Webcam", "Router", "SSD"],
    "Home": ["Coffee Maker", "Blender", "Vacuum", "Air Purifier", "Lamp", "Cookware Set"],
    "Apparel": ["T-Shirt", "Jacket", "Sneakers", "Backpack", "Hat", "Socks"],
    "Office": ["Notebook", "Pen Set", "Desk Organizer", "Chair", "Stapler", "Whiteboard"],
    "Outdoors": ["Tent", "Water Bottle", "Cooler", "Hiking Poles", "Sleeping Bag", "Lantern"],
}
FIRST_NAMES = ["Alex", "Sam", "Jordan", "Taylor", "Morgan", "Casey", "Riley", "Jamie",
               "Avery", "Quinn", "Drew", "Cameron", "Reese", "Parker", "Hayden", "Rowan"]
LAST_NAMES = ["Smith", "Johnson", "Lee", "Garcia", "Patel", "Nguyen", "Brown", "Kim",
              "Martinez", "Davis", "Lopez", "Wilson", "Anderson", "Clark", "Wright", "Hall"]


def daterange_random(rng):
    span = (END_DATE - START_DATE).days
    return START_DATE + timedelta(days=rng.randint(0, span))


def main():
    rng = random.Random(SEED)
    os.makedirs(OUT_DIR, exist_ok=True)

    # customers
    customers = []
    for i in range(1, N_CUSTOMERS + 1):
        cid = f"C{i:04d}"
        name = f"{rng.choice(FIRST_NAMES)} {rng.choice(LAST_NAMES)}"
        customers.append({
            "customer_id": cid,
            "customer_name": name,
            "region": rng.choice(REGIONS),
            "segment": rng.choice(SEGMENTS),
            "signup_date": daterange_random(rng).isoformat(),
        })

    # products
    products = []
    pid_num = 1
    for category, names in CATEGORIES.items():
        for pname in names:
            pid = f"P{pid_num:04d}"
            base = round(rng.uniform(8, 400), 2)
            products.append({
                "product_id": pid,
                "product_name": pname,
                "category": category,
                "unit_price": base,
            })
            pid_num += 1
    products = products[:N_PRODUCTS]
    price_by_pid = {p["product_id"]: p["unit_price"] for p in products}
    pids = [p["product_id"] for p in products]
    cids = [c["customer_id"] for c in customers]

    # sales
    sales = []
    for i in range(1, N_SALES + 1):
        oid = f"O{i:06d}"
        cid = rng.choice(cids)
        pid = rng.choice(pids)
        qty = rng.randint(1, 8)
        unit_price = price_by_pid[pid]
        discount = rng.choice([0, 0, 0, 0.05, 0.1, 0.15, 0.2])
        gross = qty * unit_price
        total = round(gross * (1 - discount), 2)
        sales.append({
            "order_id": oid,
            "order_date": daterange_random(rng).isoformat(),
            "customer_id": cid,
            "product_id": pid,
            "quantity": qty,
            "unit_price": unit_price,
            "discount": discount,
            "total_amount": total,
            "channel": rng.choice(CHANNELS),
        })

    def write(name, rows, fields):
        path = os.path.join(OUT_DIR, name)
        with open(path, "w", newline="", encoding="utf-8") as f:
            w = csv.DictWriter(f, fieldnames=fields)
            w.writeheader()
            w.writerows(rows)
        print(f"wrote {len(rows):>6} rows -> {path}")

    write("customers.csv", customers,
          ["customer_id", "customer_name", "region", "segment", "signup_date"])
    write("products.csv", products,
          ["product_id", "product_name", "category", "unit_price"])
    write("sales.csv", sales,
          ["order_id", "order_date", "customer_id", "product_id",
           "quantity", "unit_price", "discount", "total_amount", "channel"])
    print("done.")


if __name__ == "__main__":
    main()
