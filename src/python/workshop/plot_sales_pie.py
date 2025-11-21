from pathlib import Path
import argparse
import sqlite3
import pandas as pd
import matplotlib.pyplot as plt


def get_db_path() -> Path:
    # workshop is at src/python/workshop; shared is at src/shared
    return Path(__file__).parent.parent.parent.resolve() / "shared" / "database" / "contoso-sales.db"


def load_and_aggregate(db_path: Path, group_by: str, year: int | None, top_n: int = 8) -> pd.DataFrame:
    conn = sqlite3.connect(db_path)
    where_clause = ""
    params = ()
    if year is not None:
        where_clause = "WHERE year = ?"
        params = (year,)

    query = f"SELECT {group_by} as group_key, SUM(revenue) as revenue_sum FROM sales_data {where_clause} GROUP BY {group_by} ORDER BY revenue_sum DESC"
    df = pd.read_sql_query(query, conn, params=params)
    conn.close()

    if df.empty:
        return df

    # Consolidate small slices into 'Other' if there are many categories
    if len(df) > top_n:
        top = df.head(top_n).copy()
        others_sum = df['revenue_sum'].iloc[top_n:].sum()
        top = top.append({'group_key': 'Other', 'revenue_sum': others_sum}, ignore_index=True)
        return top

    return df


def plot_pie(df: pd.DataFrame, group_by: str, year: int | None, out_path: Path) -> None:
    plt.figure(figsize=(8, 8))
    labels = df['group_key']
    sizes = df['revenue_sum']
    plt.pie(sizes, labels=labels, autopct='%1.1f%%', startangle=140)
    title_year = str(year) if year is not None else 'all_years'
    plt.title(f"Sales by {group_by} ({title_year})")
    plt.axis('equal')
    out_path.parent.mkdir(parents=True, exist_ok=True)
    plt.tight_layout()
    plt.savefig(out_path)
    plt.close()


def main() -> None:
    parser = argparse.ArgumentParser(description='Create a sales pie chart from the Contoso sales DB')
    parser.add_argument('--group-by', choices=['main_category', 'product_type', 'region'], default='main_category', help='Field to aggregate by')
    parser.add_argument('--year', type=int, default=None, help='Reporting year to filter (optional)')
    parser.add_argument('--top', type=int, default=8, help='Number of top categories to show (others combined into Other)')
    args = parser.parse_args()

    db_path = get_db_path()
    if not db_path.exists():
        print(f"Database not found at {db_path}. Make sure the shared files are present.")
        return

    df = load_and_aggregate(db_path, args.group_by, args.year, top_n=args.top)
    if df.empty:
        print("No data found for the requested filters.")
        return

    out_file_name = f"sales_pie_{args.group_by}_{args.year or 'all'}.png"
    out_path = Path(__file__).parent.parent.parent.resolve() / 'shared' / 'files' / out_file_name

    plot_pie(df, args.group_by, args.year, out_path)
    print(f"Saved pie chart to: {out_path}")


if __name__ == '__main__':
    main()
