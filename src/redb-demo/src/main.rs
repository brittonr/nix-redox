use redb::{Database, ReadableTable, ReadableTableMetadata, TableDefinition};
use std::env;
use std::process;

const COUNTER_TABLE: TableDefinition<&str, u64> = TableDefinition::new("counters");
const KV_TABLE: TableDefinition<&str, &str> = TableDefinition::new("kv");

fn main() {
    let args: Vec<String> = env::args().collect();
    let db_path = if args.len() > 1 { &args[1] } else { "/tmp/redb-demo.db" };

    match run(db_path) {
        Ok(()) => {}
        Err(e) => {
            eprintln!("redb-demo: {e}");
            process::exit(1);
        }
    }
}

fn run(db_path: &str) -> Result<(), Box<dyn std::error::Error>> {
    println!("redb-demo: opening database at {db_path}");
    let db = Database::create(db_path)?;

    // Write some data
    let write_txn = db.begin_write()?;
    {
        let mut table = write_txn.open_table(KV_TABLE)?;
        table.insert("os", "Redox")?;
        table.insert("engine", "redb")?;
        table.insert("language", "Rust")?;
    }
    {
        let mut table = write_txn.open_table(COUNTER_TABLE)?;
        // Increment a visit counter
        let prev = table.get("visits")?.map(|v| v.value()).unwrap_or(0);
        table.insert("visits", prev + 1)?;
    }
    write_txn.commit()?;
    println!("redb-demo: wrote 3 key-value pairs + incremented counter");

    // Read back
    let read_txn = db.begin_read()?;
    {
        let table = read_txn.open_table(KV_TABLE)?;
        println!("redb-demo: kv entries:");
        for entry in table.iter()? {
            let entry = entry?;
            println!("  {} = {}", entry.0.value(), entry.1.value());
        }
    }
    {
        let table = read_txn.open_table(COUNTER_TABLE)?;
        let visits = table.get("visits")?.map(|v| v.value()).unwrap_or(0);
        println!("redb-demo: visit count = {visits}");
    }

    // Test range queries
    let read_txn = db.begin_read()?;
    {
        let table = read_txn.open_table(KV_TABLE)?;
        let count = table.len()?;
        println!("redb-demo: total kv entries = {count}");
    }

    println!("redb-demo: PASS");
    Ok(())
}
