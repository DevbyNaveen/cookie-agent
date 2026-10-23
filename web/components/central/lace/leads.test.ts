import { strict as assert } from "node:assert";
import { test } from "node:test";
import { parseLead, parseLeads } from "./leads.ts";

const ANSWER = `Five Nordic freight companies with a reason to talk now.

Halvorsen Freight (halvorsen.no) — Nordic road freight, 400 trucks. Posted a Head of Fleet Operations role on 3 October 2026. Fits because you sell route planning to fleets over 200 vehicles. Approach: Head of Operations, through halvorsen.no/contact.

2. Nordlys Logistics AB (https://www.nordlys.se/) — Warehousing and last-mile in Sweden. Raised a €12M Series A on 14 September 2026 to expand to Norway. Fits because expansion means new routes. Approach: COO, through their careers page.

Kvist Transport Inc. (kvist.dk) — Cold-chain trucking, e.g. pharma. Opened a Malmö depot in August 2026. Approach: Head of Logistics.

I searched job boards and Nordic business news from the last 12 months and left out current customers.`;

test("each lead is a slice of what Cookie wrote, with its paragraph", () => {
  const { leads, rest } = parseLeads(ANSWER);
  assert.equal(leads.length, 3);
  assert.deepEqual(leads[0], {
    company: "Halvorsen Freight",
    site: "halvorsen.no",
    what: "Nordic road freight, 400 trucks",
    signal: "Posted a Head of Fleet Operations role on 3 October 2026",
    fits: "you sell route planning to fleets over 200 vehicles",
    approach: "Head of Operations, through halvorsen.no/contact",
    para: 1,
  });
  assert.equal(leads[1].company, "Nordlys Logistics AB", "a list number is not part of the name");
  assert.equal(leads[1].site, "nordlys.se", "scheme, www and the trailing slash go");
  assert.equal(leads[1].para, 2);
  assert.equal(leads[2].what, "Cold-chain trucking, e.g. pharma", "an abbreviation does not end the sentence");
  assert.equal(leads[2].fits, "", "no fit named, none invented");
  assert.equal(leads[2].approach, "Head of Logistics");
  assert.deepEqual(rest.map((p) => p.slice(0, 12)), ["Five Nordic ", "I searched j"]);
});

test("prose with a site in brackets is not a lead", () => {
  assert.equal(parseLead("We met Acme (acme.com) — nice people. They liked the demo.", 0), null);
  assert.equal(parseLead("Northwind pays $40 a seat.", 0), null);
});

test("one lead is not a list", () => {
  const one = "Acme (acme.com) — Widgets. Hiring now. Approach: CTO.";
  assert.deepEqual(parseLeads(one), { leads: [], rest: [one] });
  assert.deepEqual(parseLeads(""), { leads: [], rest: [] });
});
