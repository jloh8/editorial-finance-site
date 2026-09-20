-- ============================================================================
-- Editorial Pipeline v1 — schema
-- Project: CoursideMeetup
-- Run once in the Supabase dashboard SQL editor (idempotent where marked).
-- ============================================================================

create extension if not exists pgcrypto;

-- ----------------------------------------------------------------------------
-- Tables
-- ----------------------------------------------------------------------------
create table if not exists editorial_articles (
  id uuid primary key default gen_random_uuid(),
  slug text unique not null,
  title text not null,
  dek text,
  status text not null default 'in_review'
    check (status in ('draft','in_review','revising','needs_revision','published')),
  current_version_id uuid,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

create table if not exists editorial_versions (
  id uuid primary key default gen_random_uuid(),
  article_id uuid not null references editorial_articles(id) on delete cascade,
  version_number int not null,
  html text not null,
  created_by text default 'rumi',
  created_at timestamptz default now(),
  unique(article_id, version_number)
);

create table if not exists editorial_revision_requests (
  id uuid primary key default gen_random_uuid(),
  article_id uuid not null references editorial_articles(id) on delete cascade,
  notes text not null,
  status text not null default 'pending'
    check (status in ('pending','done','failed')),
  created_at timestamptz default now()
);

-- current_version_id -> versions (added after both tables exist; circular ref)
do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'editorial_articles_current_version_id_fkey'
  ) then
    alter table editorial_articles
      add constraint editorial_articles_current_version_id_fkey
      foreign key (current_version_id) references editorial_versions(id);
  end if;
end $$;

-- Keep updated_at fresh on any update (admin UI flips status directly).
create or replace function public.handle_editorial_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end $$;

drop trigger if exists trg_editorial_articles_updated on editorial_articles;
create trigger trg_editorial_articles_updated
  before update on editorial_articles
  for each row execute function public.handle_editorial_updated_at();

-- ----------------------------------------------------------------------------
-- Row Level Security
-- v1: reads are public (the reader UI only renders published articles).
-- Writes are restricted to the editor's magic-link session.
-- ----------------------------------------------------------------------------
alter table editorial_articles enable row level security;
alter table editorial_versions enable row level security;
alter table editorial_revision_requests enable row level security;

drop policy if exists "anon read articles" on editorial_articles;
create policy "anon read articles" on editorial_articles
  for select to anon using (true);

drop policy if exists "anon read versions" on editorial_versions;
create policy "anon read versions" on editorial_versions
  for select to anon using (true);

drop policy if exists "anon read revision requests" on editorial_revision_requests;
create policy "anon read revision requests" on editorial_revision_requests
  for select to anon using (true);

drop policy if exists "editor full access articles" on editorial_articles;
create policy "editor full access articles" on editorial_articles
  for all to authenticated
  using ((auth.jwt() ->> 'email') = 'jiajingloh@gmail.com')
  with check ((auth.jwt() ->> 'email') = 'jiajingloh@gmail.com');

drop policy if exists "editor full access versions" on editorial_versions;
create policy "editor full access versions" on editorial_versions
  for all to authenticated
  using ((auth.jwt() ->> 'email') = 'jiajingloh@gmail.com')
  with check ((auth.jwt() ->> 'email') = 'jiajingloh@gmail.com');

drop policy if exists "editor full access revision requests" on editorial_revision_requests;
create policy "editor full access revision requests" on editorial_revision_requests
  for all to authenticated
  using ((auth.jwt() ->> 'email') = 'jiajingloh@gmail.com')
  with check ((auth.jwt() ->> 'email') = 'jiajingloh@gmail.com');

-- ----------------------------------------------------------------------------
-- RPC: editorial_complete_revision
-- Called by the automated revision worker (no service key needed).
-- SECURITY DEFINER runs as the table owner, bypassing RLS.
-- Worst-case abuse: flipping a 'revising' draft back to review — drafts never
-- render publicly, so the blast radius is an editorial status change.
-- ----------------------------------------------------------------------------
create or replace function public.editorial_complete_revision(p_request_id uuid, p_html text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_req editorial_revision_requests%rowtype;
  v_art editorial_articles%rowtype;
  v_next int;
  v_new_version_id uuid;
begin
  select * into v_req from editorial_revision_requests where id = p_request_id;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'request_not_found');
  end if;
  if v_req.status <> 'pending' then
    return jsonb_build_object('ok', false, 'error', 'request_not_pending');
  end if;
  select * into v_art from editorial_articles where id = v_req.article_id;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'article_not_found');
  end if;

  -- Notes unclear / nothing to apply: send it back to the editor.
  if p_html is null or btrim(p_html) = '' then
    update editorial_revision_requests set status = 'failed' where id = p_request_id;
    update editorial_articles set status = 'in_review', updated_at = now() where id = v_art.id;
    return jsonb_build_object('ok', true, 'outcome', 'failed',
                              'message', 'notes unclear; article returned to review');
  end if;

  if v_art.status <> 'revising' then
    return jsonb_build_object('ok', false, 'error', 'article_not_revising');
  end if;

  select coalesce(max(version_number), 0) + 1 into v_next
    from editorial_versions where article_id = v_art.id;

  insert into editorial_versions(article_id, version_number, html, created_by)
    values (v_art.id, v_next, p_html, 'rumi')
    returning id into v_new_version_id;

  update editorial_articles
    set current_version_id = v_new_version_id,
        status = 'in_review',
        updated_at = now()
    where id = v_art.id;

  update editorial_revision_requests set status = 'done' where id = p_request_id;

  return jsonb_build_object('ok', true, 'outcome', 'done', 'version_number', v_next);
end;
$$;

grant execute on function public.editorial_complete_revision(uuid, text) to anon;

-- ----------------------------------------------------------------------------
-- Seed: Detroit documentary, version 1
-- ----------------------------------------------------------------------------
with a as (
  insert into editorial_articles (slug, title, dek, status)
  values (
    'detroit-auto-rise-fall',
    'How Detroit built the car — and lost the industry',
    $$From the Model T to the largest municipal bankruptcy in American history: a century of the Motor City, and what it says about American industry.$$,
    'in_review'
  )
  on conflict (slug) do update
    set title = excluded.title, dek = excluded.dek
  returning id
),
v as (
  insert into editorial_versions (article_id, version_number, html, created_by)
  select id, 1, $$  <section class="hero">
    <p class="kicker">Featured documentary</p>
    <h1>How Detroit built the car — and lost the industry</h1>
    <p class="dek">From the Model T to the largest municipal bankruptcy in American history: a century of the Motor City, and what it says about American industry.</p>
    <p class="byline">By Editorial Finance · Research read September 20, 2026 · All figures sourced below</p>
  </section>

  <section class="figures" aria-label="Key figures">
    <div class="fig"><div class="n">15M+</div><div class="l">Model Ts produced by 1927</div></div>
    <div class="fig"><div class="n">93 min</div><div class="l">Chassis assembly time after the 1913 moving line — down from ~12.5 hours</div></div>
    <div class="fig"><div class="n">90.6%</div><div class="l">Detroit Three share of the U.S. auto market, 1965 peak</div></div>
    <div class="fig"><div class="n">~38%</div><div class="l">Detroit Three combined U.S. share, 2024</div></div>
    <div class="fig"><div class="n">$9.26B</div><div class="l">Net taxpayer loss on the 2008–09 auto bailouts</div></div>
    <div class="fig"><div class="n">$18.5B</div><div class="l">Liabilities in Detroit's 2013 Chapter 9 filing — largest municipal bankruptcy in U.S. history</div></div>
  </section>

  <article>
    <section class="chapter">
      <p class="chapnum">Chapter 1</p>
      <h2>The Rise</h2>
      <p>Henry Ford incorporated the Ford Motor Company in 1903 promising "a car for the great multitude." The first Model Ts went on sale in <strong>1908</strong> at $950 — within a decade the price fell to $280. In 1913 the moving assembly line began operations at Ford's Highland Park plant, cutting chassis assembly from roughly a twelve-hour job to <strong>93 minutes</strong>. By 1927, when production ceased, more than <strong>15 million</strong> Model Ts had been built; at the height of its popularity 40% of all new cars sold in America were Model Ts, and at one point half of all automobiles on Earth carried the Ford badge. By 1925 the Highland Park plant was turning out more than 9,000 a day.</p>
      <p>In January <strong>1914</strong>, Ford raised pay to $5 a day for eight hours — more than double the average factory wage — after cutting the workday from nine to eight hours to run three shifts. Thousands lined up in bitter cold outside the plant. The motive was not philanthropy. Ford corporate historian Bob Kreipke put it plainly:</p>
      <blockquote>"It was mainly to stabilize the workforce. And it sure did."<cite>— Bob Kreipke, Ford historian, via NPR</cite></blockquote>
      <p>Turnover had been crippling the new assembly lines, and the raise, Kreipke said, "raised the bar all over the world."</p>
      <p>Detroit was already a Great Lakes shipping and manufacturing hub when some <strong>125 automotive companies were founded in the city alone</strong> in the early 20th century — including all of the Big Three. General Motors was founded in Flint on September 16, 1908, by William C. Durant as a holding company for Buick, rapidly acquiring Oldsmobile, Cadillac and Oakland (Pontiac). Chrysler followed on June 6, 1925. By the 1920s Detroit was the undisputed world capital of the industry — what historian Kevin Boyle calls "the Silicon Valley of America… the most innovative, cutting-edge dominant industry in the world." Auto manufacturing employment in the city of Detroit itself peaked in 1950 at just over 220,000 workers; Ford's River Rouge complex alone employed more than 100,000 at its height.</p>
    </section>

    <section class="chapter">
      <p class="chapnum">Chapter 2</p>
      <h2>The Golden Age</h2>
      <p>The Detroit Three's U.S. market share peaked at <strong>90.6% in 1965</strong>. In the 1950s GM alone held roughly 46% of the American market and employed more than 600,000 Americans; in 1955 it became the first American company to earn more than $1 billion in profit in a single year. Detroit's population peaked in the <strong>1950 Census at 1,849,568</strong> — then the fifth-largest city in the United States — and fell in every census after.</p>
      <p>The era's social contract was sealed in 1950, when GM and the UAW signed the "Treaty of Detroit": workers traded hopes for shorter hours and shop-floor power for health and retirement benefits plus a cost-of-living adjustment. The arrangement anchored a quarter-century of labor peace. Economist Daniel Bell observed that GM "paid a billion for peace but it got a bargain." The political myth of the age held that what was good for General Motors was good for America.</p>
    </section>

    <section class="chapter">
      <p class="chapnum">Chapter 3</p>
      <h2>The Decline</h2>
      <p>The <strong>1973 OPEC oil embargo</strong> detonated the "Malaise Era." Detroit's big V8s became liabilities overnight; rushed small cars like the Ford Pinto, Chevy Vega and AMC Gremlin contrasted with Japanese subcompacts — the Honda Civic, Toyota Corolla, Datsun B210 — often delivering 40+ mpg. The 1979 second oil shock compounded the damage.</p>
      <p>The decisive edge was <strong>quality as much as fuel economy</strong>. Japanese makers had adopted the statistical quality-control theories of W. Edwards Deming — an American rebuffed by U.S. manufacturers — while "made in Japan" shed its inferior reputation. With little import competition, the Big Three, in a Heritage Foundation account of the era, "emphasized style over quality and cost control" while Toyota pioneered "lean production."</p>
      <p>Washington's answer was the Reagan administration's <strong>1981 "voluntary export restraint"</strong>, capping Japanese auto exports at 1.68 million vehicles a year. It lasted more than a decade. Americans paid an estimated extra $5 billion; the average new-car price rose about $2,600 — and the industry posted a record $10 billion profit in 1984. Protection bought breathing room, not reform.</p>
      <p>Meanwhile the geography of American carmaking was being redrawn. Volkswagen opened the first "transplant" at Westmoreland, Pennsylvania, in 1978; Honda's Marysville, Ohio, Accord line followed in 1982, Nissan's Smyrna, Tennessee, in 1983, Toyota's Georgetown, Kentucky, in 1988, then BMW in South Carolina (1994), Mercedes in Alabama (1997), Hyundai in Alabama (2005), Kia in Georgia (2009) and VW in Tennessee (2011). The Southern plants were deliberately non-union. By 2024, <strong>foreign brands were producing more vehicles in the U.S. than the Detroit Three</strong>.</p>
      <p>Labor's leverage collapsed in parallel. UAW membership peaked in <strong>1979 at 1.5 million</strong>; today it stands at roughly 400,000, with just under 150,000 autoworkers. The 2008–09 bailout terms forced the automakers to eliminate the UAW "jobs bank" and make union compensation competitive with the transplants.</p>
      <p>The hollowing had started earlier, and closer to home. Detroit's deindustrialization began well before the 1967 riots: the city had 338,400 manufacturing jobs in 1947; 138,000 vanished by 1963 and another 50,000 by 1977. Between 1946 and 1956 the Big Three spent billions on <strong>25 new plants — all in Detroit's suburbs, none in the city</strong>. Federally backed mortgages favored new white suburbs while redlining starved inner-city neighborhoods; the 1956 highway program bulldozed Black neighborhoods like Black Bottom and Paradise Valley. The July 1967 uprising left 43 dead, more than 7,000 arrested and 2,000+ buildings destroyed; some 67,000 residents left in 1968 and another 80,000 in 1969. Coleman Young was elected Detroit's first Black mayor in 1973.</p>
      <p>There was a precedent for rescue. In 1979–80, with Chrysler near bankruptcy, Lee Iacocca won the Chrysler Corporation Loan Guarantee Act — <strong>$1.5 billion in federal loan guarantees</strong>, then the largest government rescue of a private company. Chrysler drew $1.2 billion, repaid it within three years — seven years early — and taxpayers earned $311 million on stock warrants plus $25 million in fees. Iacocca's line: <strong>"We at Chrysler borrow money the old-fashioned way. We pay it back."</strong> The company then launched its fuel-efficient K-cars.</p>
    </section>

    <section class="chapter">
      <p class="chapnum">Chapter 4</p>
      <h2>The Fall</h2>
      <p>In December 2008, after Congress failed to pass an auto bill, President Bush authorized <strong>$17.4 billion in TARP bridge loans</strong> — $9.4 billion to GM, $4 billion to Chrysler — with a March 31, 2009, deadline to prove viability. Chrysler filed for Chapter 11 on <strong>April 30, 2009</strong>, the first major U.S. automaker bankruptcy since Studebaker in 1933, and emerged in a Fiat alliance with a UAW retiree health-care trust holding a 55% stake. <strong>GM filed on June 1, 2009</strong> — with $172.81 billion in debt against $82.29 billion in assets, the fourth-largest bankruptcy in U.S. history — and emerged on July 10 as a new company roughly 60% owned by the U.S. Treasury. A $23 billion IPO followed in November 2010; the Treasury sold its final GM shares in December 2013, and Chrysler repaid its loans in June 2011. Ford took no federal aid, having arranged a large credit line in 2007.</p>
      <p>The final taxpayer cost: Treasury invested <strong>$79.69 billion</strong> and recovered <strong>$70.43 billion</strong> — a net loss of <strong>$9.26 billion</strong>, far below the $30–44 billion feared in 2009. The Center for Automotive Research estimated the bailouts saved 1.2 million jobs at GM alone and preserved $284.4 billion in personal income.</p>
      <p>Then the city itself fell. On <strong>July 18, 2013</strong>, Detroit filed for <strong>Chapter 9 bankruptcy</strong> — the largest municipal bankruptcy in U.S. history at an estimated <strong>$18–18.5 billion</strong> in debt and liabilities. Emergency manager Kevyn Orr, appointed by Michigan Governor Rick Snyder, filed after creditor negotiations failed. Snyder's letter to the filing read: "Only one feasible path offers a way out." The city had lost 250,000 residents — a quarter of its population — between 2000 and 2010 alone, destroying its tax base.</p>
    </section>

    <section class="chapter">
      <p class="chapnum">Chapter 5</p>
      <h2>Aftermath</h2>
      <p>Today the U.S. auto industry employs <strong>about one million manufacturing workers</strong> — roughly the same as the 1950–1993 average of 1.1 million — with output and real value-added at all-time highs. The story is relocation, not collapse: Michigan has about 280,000 fewer auto jobs than in the 1950s, a roughly 60% decline, while foreign transplants build more vehicles in America than the Detroit Three. In 2021, <strong>Toyota outsold GM in the U.S. for the first time ever</strong> — 2.33 million vehicles to 2.2 million — ending GM's 89-year run atop the American market. The Detroit Three's combined share sits at roughly <strong>38%</strong>: GM 16.5%, Ford 13.3%, Stellantis 8.5%. In September 2023, the UAW struck all three Detroit automakers simultaneously for the first time.</p>
      <p>The electric transition has been turbulent. A 2023 Bank of America "Car Wars" study had Tesla holding 78% of U.S. EV sales in 2018, projected to fall to about 18% by 2026, with the Detroit Three collectively projected to take 31% of the EV market. Then the pullback: more than $20 billion in previously announced EV and battery investments were wiped out in 2025. Ford downsized its BlueOval City battery plant from $3.5 billion and 2,500 jobs to $2 billion and 1,700 jobs; GM sold its stake in the Lansing Ultium Cells battery plant in May 2025. Stellantis CEO Antonio Filosa admitted "the pace of the energy transition had been overestimated."</p>
      <p>And Detroit itself? The 2020 Census counted <strong>639,111</strong> residents — the lowest since 1910. But in May 2024, Census estimates showed the city growing for the first time in decades, up 1,852 people. "It's a great day… The city of Detroit has joined the communities in America that are growing in population," said Mayor Mike Duggan. The July 2025 estimate put the population at <strong>649,095</strong> — three straight years of growth. The Motor City is not back. But for the first time in seventy years, it is no longer shrinking.</p>
    </section>
  </article>

  <section class="card">
    <h2>Detroit's population, 1920–2025</h2>
    <p class="sub">U.S. Census figures; the city's population peaked in 1950 and fell in every census after — until 2023.</p>
    <svg class="chart" id="popChart" viewBox="0 0 720 400" role="img" aria-label="Line chart of Detroit population from 1920 to 2025"></svg>
    <p class="chartnote">1960 and 1970 computed from the reported decade declines (−179,000 and −156,000). 2025 is the Census Vintage estimate (July 1). Sources: U.S. Census via Detroit Free Press; nchstats.com.</p>
  </section>

  <section class="card">
    <h2>Market share: from nine in ten to fewer than four in ten</h2>
    <p class="sub">Detroit Three share of U.S. auto sales</p>
    <div class="bar-row">
      <div class="blabel">1965 — 90.6% (peak)</div>
      <div class="bar-track"><div class="bar-fill old" style="width:90.6%">90.6%</div></div>
    </div>
    <div class="bar-row">
      <div class="blabel">2024 — ~38% combined</div>
      <div class="bar-track"><div class="bar-fill" style="width:38%">~38%</div></div>
    </div>
    <p class="chartnote">The Detroit Three fell below 50% of U.S. sales for the first time in July 2007. Definitions vary across sources (cars vs. light vehicles); direction and magnitude are consistent. Sources: AEI chart data; MarkLines via MotorBiscuit; Motor Authority.</p>
  </section>

  <section class="card caveats">
    <h2>Where the experts disagree</h2>
    <p class="sub">Reputable sources genuinely differ on how to weight the causes. They are not mutually exclusive — the honest account is that Detroit suffered several of these at once.</p>
    <ul>
      <li><strong>The labor-cost argument.</strong> The UAW's above-market wage and benefit premiums pushed production to non-union Southern transplants and drove market share from 90.6% to under half. <span class="slant">— AEI (conservative), which calls the UAW a "government-sanctioned labor monopoly."</span></li>
      <li><strong>The management-complacency argument.</strong> The Big Three's dominance was "an accident of history" — America emerged from WWII as the only intact industrial power — and executives came to regard domination of the North American market as the norm, emphasizing style over quality and cost control. <span class="slant">— MotorTrend; Heritage Foundation.</span></li>
      <li><strong>The race-and-deindustrialization argument.</strong> The decline began in the 1940s–50s, not the 1970s: discrimination, the 25 suburban plants, and residential segregation hollowed the city first; the 1967 uprising and white flight were accelerants, not origins. <span class="slant">— Historian Thomas Sugrue (Princeton UP); In These Times (left).</span></li>
      <li><strong>The automation argument.</strong> Detroit's auto employment collapse predates the 1970s trade shocks — the biggest city-level losses happened by 1970 — while national output is at all-time highs. Relocation, not collapse. <span class="slant">— Economist Adam Ozimek; Enrico Moretti.</span></li>
      <li><strong>The trade-policy argument.</strong> An estimated 360,000 U.S. auto jobs were lost to NAFTA while Mexico gained 620,000. Counter-argument: import restraints mainly raised consumer prices and shielded the Big Three from competition they needed. <span class="slant">— EPI/UAW-aligned figures (contested) vs. free-market economists.</span></li>
    </ul>
    <h2 style="margin-top:26px">What we could not firmly verify</h2>
    <ul>
      <li>The exact day of the first Model T sale (October 1, 1908, is single-sourced); mainstream sources confirm 1908 only. We use the year.</li>
      <li>The pre-assembly-line build time: one source says 12.5 hours, others 728 minutes. We describe it as "roughly a twelve-hour job."</li>
      <li>The claim that the $5 day raised wages "from $2.34 for a 9-hour day" is single-sourced; Ford's actual scheme included a profit-sharing component with eligibility rules.</li>
      <li>The famous Charles Wilson phrasing — "what's good for General Motors is good for the country" — was not verified from a primary source; we use the NY Review of Books paraphrase.</li>
      <li>Detroit's bankruptcy exit date was not independently verified; we report the July 18, 2013 filing only.</li>
    </ul>
  </section>

  <section class="card srclist">
    <h2>Sources</h2>
    <p class="sub">Grouped by type. All read September 20, 2026 via web index (not live-verified). Think-tank orientations noted in the text.</p>
    <h3>Government &amp; statistics</h3>
    <ul>
      <li><a href="https://www.bls.gov/iag/tgs/iagauto.htm?ftag=YHFa5b931b">Bureau of Labor Statistics — auto industry employment</a></li>
      <li><a href="https://www.census.gov/quickfacts/fact/table/detroitcitymichigan,waynecountymichigan,MI,US/PST045218">U.S. Census QuickFacts — Detroit (2020 census; 2025 estimates)</a></li>
      <li><a href="https://www.EveryCRSReport.com/files/20120907_R41940_1beab764658396183f144de5da629cd8135835de.pdf">Congressional Research Service — Chrysler restructuring</a></li>
      <li><a href="https://www.chicagofed.org/-/media/others/events/2009/automotive-communities/presentation-shifting-automotive-geography-pdf.pdf">Federal Reserve Bank of Chicago — Detroit Three market-share chart</a></li>
    </ul>
    <h3>Wire services &amp; major press</h3>
    <ul>
      <li><a href="https://www.publicradioeast.org/us/2014-01-27/the-middle-class-took-off-100-years-ago-thanks-to-henry-ford">NPR — the $5 workday, 100 years on</a></li>
      <li><a href="https://www.publicradioeast.org/us/2013-07-18/detroit-files-for-bankruptcy">NPR — Detroit files for bankruptcy, July 18, 2013</a></li>
      <li><a href="https://www.cfpublic.org/2018-08-03/can-a-reagan-era-policy-offer-an-alternative-to-tariffs">NPR — the 1981 voluntary export restraint</a></li>
      <li><a href="https://gmg-wdiv-prod.cdn.arcpublishing.com/news/national/2024/05/16/census-estimates-detroit-population-rises-after-decades-of-decline-south-still-dominates-us-growth/">AP — Detroit population grows for first time in decades (May 2024)</a></li>
      <li><a href="https://www.beaconjournal.com/story/news/2017/05/25/new-census-data-show-detroits-population-decline-continues/341336001/">Detroit Free Press — 1950 population peak, 1,849,568</a></li>
      <li><a href="https://www.beaconjournal.com/story/money/cars/2025/02/04/canada-mexico-us-auto-manufacturing-history-ford-gm-chrysler/78182033007/">Detroit Free Press — maquiladoras and the integrated supply chain</a></li>
      <li><a href="https://www.beaconjournal.com/story/money/cars/2018/02/28/tennessee-auto-industry-nissan-smyrna-gm-spring-hill-volkswagen-chattanooga/1028963001/">Detroit Free Press — Nissan Smyrna and the Southern strategy</a></li>
      <li><a href="https://techxplore.com/news/2022-01-toyota-tops-auto-sales.amp">Tech Xplore/CNBC — Toyota outsells GM in the U.S., 2021</a></li>
    </ul>
    <h3>Encyclopedias &amp; history</h3>
    <ul>
      <li><a href="https://www.history.com/articles/michigan">HISTORY — Michigan and the auto chronology</a></li>
      <li><a href="https://en.wikipedia.org/wiki/Detroit_bankruptcy">Wikipedia — Detroit bankruptcy (filing, liabilities)</a></li>
      <li><a href="https://en.wikipedia.org/wiki/Chrysler_Chapter_11_reorganization">Wikipedia — Chrysler Chapter 11 reorganization</a></li>
      <li><a href="https://en.wikipedia.org/wiki/Chrysler_Corporation_Loan_Guarantee_Act_of_1979">Wikipedia — 1979 Chrysler loan guarantee act</a></li>
      <li><a href="https://en.wikipedia.org/wiki/Effects_of_the_2008–2010_automotive_industry_crisis_on_the_United_States">Wikipedia — 2008–10 auto industry crisis</a></li>
      <li><a href="https://www.nybooks.com/online/2023/09/23/eight-and-skate-uaw-strike/">NY Review of Books — the Treaty of Detroit</a></li>
      <li><a href="https://origins.osu.edu/index.php/connecting-history/strikes-lordstown-haymarket-pullman-shirtwaist-uaw-ufw-afl">Ohio State Origins — Treaty of Detroit background</a></li>
      <li><a href="https://www.u-s-history.com/pages/h1809.html">u-s-history.com — GM founding; 1955 $1B profit</a></li>
    </ul>
    <h3>Think tanks &amp; analysis</h3>
    <ul>
      <li><a href="https://www.aei.org/carpe-diem/uaw-as-a-government-sanctioned-labor-monopoly-that-drove-big-3s-market-share-from-90-in-1965-to-now-below-44/">AEI (conservative) — the union-blame thesis</a></li>
      <li><a href="https://www.aei.org/economics/must-there-always-be-a-detroit/">AEI — Glaeser/Moretti on reinvention failure</a></li>
      <li><a href="https://aier.org/article/why-detroit-failed-and-pittsburgh-recovered/">AIER (free-market) — industrial monoculture thesis</a></li>
      <li><a href="https://www.heritage.org/node/20770/print-display">Heritage Foundation (conservative) — lean production vs. Detroit</a></li>
      <li><a href="https://www.heritage.org/environment/report/the-costly-truth-about-auto-import-quotas">Heritage Foundation — the cost of import quotas</a></li>
      <li><a href="https://www.inthesetimes.com/article/decades-of-discrimination-and-corporate-chaos">In These Times (left) — race and deindustrialization</a></li>
      <li><a href="https://marginalrevolution.com/marginalrevolution/2025/08/the-economics-of-the-u-s-auto-industry-a-brief-history.html">Marginal Revolution — Ozimek on auto employment</a></li>
      <li><a href="https://americanbusinesshistory.org/50-years-of-change-in-american-manufacturing-employment/">American Business History — manufacturing employment trends</a></li>
    </ul>
    <h3>Trade &amp; automotive press</h3>
    <ul>
      <li><a href="https://hagerty.com/media/news/greatest-car-of-1890-1910-fords-model-t/">Hagerty — the Model T</a></li>
      <li><a href="http://www.wardsauto.com/news/archive-wards-energy-crisis-aided-japanese-imports/763565/">Ward's Auto — the energy crisis and Japanese imports</a></li>
      <li><a href="https://www.wardsauto.com/news/archive-wards-foreign-invasion-imports-transplants-change-auto-industry-forever/762243/">Ward's Auto — the transplant timeline</a></li>
      <li><a href="https://headlight.news/2024/07/10/foreign-brands-now-produce-more-vehicles-in-the-u-s-than-detroits-big-three/">Headlight News — foreign brands outproduce the Big Three</a></li>
      <li><a href="https://www.motortrend.com/features/the-big-picture-there-is-no-more-big-3-get-used-to-it-5">MotorTrend — "accident of history"</a></li>
      <li><a href="https://www.motorbiscuit.com/automaker-highest-us-market-share-2024/">MotorBiscuit — 2024 U.S. market shares</a></li>
      <li><a href="https://www.motorauthority.com/news/1026801_detroit-3-drop-below-50-of-u-s-market-share">Motor Authority — Detroit Three below 50%, July 2007</a></li>
      <li><a href="https://www.manufacturing.net/supply-chain/news/13067272/1979-chrysler-loan-guarantee-offers-lessons-to-big-3">Manufacturing.net — the 1979 Chrysler rescue</a></li>
      <li><a href="https://www.thetruthaboutcars.com/2014/12/us-treasury-9b-lost-auto-industry-bailout/">The Truth About Cars — final bailout tally</a></li>
      <li><a href="https://www.autoblog.com/2013/12/10/gm-chrysler-bailouts-saved-money-jobs/">Autoblog — jobs saved by the bailouts</a></li>
      <li><a href="https://goldsea.com/article_details/gm-files-for-chapter-11-bankruptcy-protection">GoldSea — GM's June 1, 2009 filing</a></li>
      <li><a href="https://www.companieshistory.com/general-motors/">CompaniesHistory — GM's 2010 IPO</a></li>
      <li><a href="https://www.energytrend.com/news/20230714-32666.html">EnergyTrend — BofA "Car Wars" EV projections</a></li>
      <li><a href="https://pv-magazine-usa.com/2025/08/19/are-evs-booming-or-idling-in-detroit/">PV Magazine — the 2025 EV pullback</a></li>
      <li><a href="https://nchstats.com/detroits-population-growth/">NCHStats — Detroit's 2025 population estimate</a></li>
      <li><a href="https://internationalsocialism.net/can-the-uaw-make-history-again/">International Socialism — UAW membership and the 2023 strike</a></li>
    </ul>
  </section>

  <footer>
    <p>Editorial Finance — prototype for testing only. Article content is drawn from indexed web research read September 20, 2026; sources are linked above. Comments are intentionally omitted from this prototype.</p>
  </footer>
$$, 'rumi' from a
  on conflict (article_id, version_number) do nothing
  returning id, article_id
)
update editorial_articles ar
set current_version_id = v.id
from v where ar.id = v.article_id and ar.current_version_id is null;

update editorial_articles ar
set current_version_id = ev.id
from editorial_versions ev
where ar.slug = 'detroit-auto-rise-fall'
  and ev.article_id = ar.id and ev.version_number = 1
  and ar.current_version_id is null;
