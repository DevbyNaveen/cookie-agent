//! Reading a tool's JSON arguments with messages a model can act on.

use serde_json::{Map, Value};

pub struct Args<'a> {
    map: &'a Map<String, Value>,
    what: String,
}

impl<'a> Args<'a> {
    /// `value` must be an object holding only `allowed` keys.
    pub fn new(value: &'a Value, what: &str, allowed: &[&str]) -> Result<Self, String> {
        let map = value.as_object().ok_or_else(|| format!("{what} must be an object"))?;
        if let Some(key) = map.keys().find(|k| !allowed.contains(&k.as_str())) {
            return Err(format!("{what} has an unknown field `{key}`; allowed: {}", allowed.join(", ")));
        }
        Ok(Self { map, what: what.to_string() })
    }

    pub fn get(&self, key: &str) -> Option<&'a Value> {
        self.map.get(key).filter(|v| !v.is_null())
    }

    pub fn has(&self, key: &str) -> bool {
        self.get(key).is_some()
    }

    pub fn str(&self, key: &str) -> Result<&'a str, String> {
        self.opt_str(key)?.ok_or_else(|| format!("{} needs `{key}`", self.what))
    }

    pub fn opt_str(&self, key: &str) -> Result<Option<&'a str>, String> {
        match self.get(key) {
            None => Ok(None),
            Some(Value::String(s)) => Ok(Some(s)),
            Some(_) => Err(format!("`{key}` in {} must be text", self.what)),
        }
    }

    pub fn bool(&self, key: &str) -> Result<bool, String> {
        match self.get(key) {
            None => Ok(false),
            Some(Value::Bool(b)) => Ok(*b),
            Some(_) => Err(format!("`{key}` in {} must be true or false", self.what)),
        }
    }

    pub fn array(&self, key: &str) -> Result<&'a Vec<Value>, String> {
        self.opt_array(key)?.ok_or_else(|| format!("{} needs `{key}` (a list)", self.what))
    }

    pub fn opt_array(&self, key: &str) -> Result<Option<&'a Vec<Value>>, String> {
        match self.get(key) {
            None => Ok(None),
            Some(Value::Array(a)) => Ok(Some(a)),
            Some(_) => Err(format!("`{key}` in {} must be a list", self.what)),
        }
    }

    pub fn opt_u64(&self, key: &str) -> Result<Option<u64>, String> {
        match self.get(key) {
            None => Ok(None),
            Some(v) => v.as_u64().map(Some).ok_or_else(|| format!("`{key}` in {} must be a whole number", self.what)),
        }
    }
}

/// A list of strings.
pub fn strings(value: &Value, what: &str) -> Result<Vec<String>, String> {
    value
        .as_array()
        .ok_or_else(|| format!("{what} must be a list of text"))?
        .iter()
        .map(|v| v.as_str().map(str::to_string).ok_or_else(|| format!("{what} must be a list of text")))
        .collect()
}

/// A cell written as text: numbers as JSON prints them, booleans, empty for null.
pub fn plain_text(value: &Value) -> Result<String, String> {
    Ok(match value {
        Value::Null => String::new(),
        Value::String(s) => s.clone(),
        Value::Number(n) => n.to_string(),
        Value::Bool(b) => b.to_string(),
        other => return Err(format!("a cell must be text, a number, true/false or null, not {other}")),
    })
}
