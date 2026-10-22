# Power BI report

This covers course requirement 5: a report with at least 4 visualizations, built on
data from your own database. The report is **already built** and lives in the
repository as a Power BI project:

```
src/bi/HBOMax.pbip                 open this file with Power BI Desktop
src/bi/HBOMax.SemanticModel/       the model, as TMDL
src/bi/HBOMax.Report/              the report, as PBIR
```

It has **5 pages and 27 visuals**, well past the 4 required. Every visual reads one
of the seven analytic views from `src/dw/15_dw_analytic_views.sql`. Each view was
shaped for the visual that consumes it (see the `CONSUMED BY` note above each view),
so the report needs no DAX at all; `src/bi/measures.dax` is an optional extra,
covered in the last section.

> Power BI Desktop runs on **Windows only**. Open the report on the same machine as
> the SQL Server instance where you ran scripts 01–16.

---

## 1. Open it

1. Run scripts `01`–`16` in order (see the README), so `HBOMaxDW` holds data.
   Check result set 5 of `16_run_full_load.sql`: all seven views must return more
   than 0 rows, or the matching page will be empty.
2. Double-click `src/bi/HBOMax.pbip`. Power BI Desktop opens the model and all five
   pages.
3. A yellow bar appears: *"Some of the tables have incomplete or no data."* Click
   **Refresh now**. This is normal and is the point of the `.pbip` format — the
   project stores the model and the report definition as text, never a copy of the
   data, so the repository stays small and the report always shows the current
   contents of your warehouse.
4. If your SQL Server is not `localhost\SQLEXPRESS`, change it once instead of
   editing any query: **Home › Transform data › Edit parameters**, and set
   `SqlServerInstance` (and `SqlServerDatabase` if you renamed the database).

## 2. The model

Seven tables, one per analytic view, imported over two Power Query parameters:

| Table | View | Grain |
|---|---|---|
| Viewing Trend | `vw_ViewingTrendByMonthRegion` | month × region |
| Top Titles | `vw_TopTitlesByHoursWatched` | title |
| Revenue and MRR | `vw_RevenueAndMrrByPlan` | month × plan |
| Cohort Retention | `vw_ChurnByCohort` | signup cohort × activity month |
| Genre Engagement | `vw_GenreEngagementByDayPart` | genre × day part |
| Device Mix | `vw_DeviceMixByRegion` | region × form factor |
| Originals vs Licensed | `vw_OriginalsVsLicensedPerformance` | content source |

Two things are already set up for you, which are easy to miss when building a report
by hand:

- **Sort columns.** `MonthLabel` sorts by `MonthKey`, `DayPart` by `DayPartSortOrder`,
  `CohortLabel` by `CohortMonthKey` and `ActivityMonthLabel` by `ActivityMonthKey`, so
  months and day parts appear in calendar order rather than A–Z.
- **Summarization.** Key columns are hidden and set to *Don't summarize*; additive
  measures default to Sum and ratios (percentages, ratings) to Average, so dragging a
  field onto a visual never silently sums a percentage.

The views are pre-aggregated and self-contained, so the model deliberately has **no
relationships**. One page's slicers therefore cannot leak into another page's visuals.

## 3. The pages

### Page 1 — Viewing overview (9 visuals)

| Visual | Table | Fields |
|---|---|---|
| Card ×4 | Viewing Trend | hours watched, sessions, binge sessions, active viewers |
| Slicer | Viewing Trend | `CalendarYear` |
| Line chart | Viewing Trend | `MonthLabel` × `HoursWatched`, legend `RegionName` |
| Clustered bar chart | Viewing Trend | `RegionName` × `HoursWatched` |
| Matrix | Genre Engagement | rows `GenreName`, columns `DayPart`, values `HoursWatched` |
| Line chart | Viewing Trend | `MonthLabel` × average `AvgCompletionPct` |

### Page 2 — Content performance (4 visuals)

| Visual | Table | Fields |
|---|---|---|
| Clustered bar chart | Top Titles | top 20 titles by `HoursWatched` (visual filter `HoursRank ≤ 20`) |
| Table | Top Titles | title, genre, source, unique viewers, completion %, rating (same filter) |
| Clustered column chart | Originals vs Licensed | `ContentSource` × `ShareOfHoursPct` and `CatalogueSharePct` |
| Donut chart | Originals vs Licensed | `HoursWatched` by `ContentSource` |

The two share-of-% columns side by side are the interesting pair: they show whether
originals pull a larger share of viewing than their share of the catalogue.

### Page 3 — Revenue and plans (6 visuals)

| Visual | Table | Fields |
|---|---|---|
| Line and stacked column combo | Revenue and MRR | `MonthLabel`, columns `RecognisedRevenue` by `PlanName`, line `Mrr` |
| Card ×2 | Revenue and MRR | recognised revenue, average payment failure rate % |
| Slicer | Revenue and MRR | `PlanName` |
| Matrix | Revenue and MRR | rows `PlanName`, columns `MonthLabel`, values `ArpuRecognised` |
| Clustered column chart | Revenue and MRR | `MonthLabel` × `NewSubscriptions` and `ChurnedSubscriptions` |

Revenue is cash-basis and carried per plan currency, so slice by `CurrencyCode`
before reading a total across plans in different currencies.

### Page 4 — Retention (4 visuals)

| Visual | Table | Fields |
|---|---|---|
| Matrix (cohort triangle) | Cohort Retention | rows `CohortLabel`, columns `MonthsSinceSignup`, values `RetentionVsCohortStartPct` |
| Line chart | Cohort Retention | `ActivityMonthLabel` × average `ChurnRatePct` |
| Line chart | Cohort Retention | `ActivityMonthLabel` × `SubscriptionsObserved` and `SubscribersChurned` |
| Slicer | Cohort Retention | `CohortLabel` |

### Page 5 — Devices and quality (4 visuals)

| Visual | Table | Fields |
|---|---|---|
| 100% stacked bar chart | Device Mix | `RegionName` × `HoursWatched`, legend `FormFactor` |
| Clustered column chart | Device Mix | `FormFactor` × average `BufferingEventsPerHour`, legend `RegionName` |
| Donut chart | Device Mix | `HoursWatched` by `FormFactor` |
| Table | Device Mix | region, form factor, devices, sessions, hours, buffering per hour |

## 4. Finishing touches

These are cosmetic and deliberately left out of the generated project, because they
are two clicks each and a matter of taste:

- **Heat map on the two matrices.** Select the matrix, then **Format › Cell elements
  › Background color: on**. On page 1 this turns genre × day part into a heat map; on
  page 4 it turns the cohort triangle into the usual red-to-green retention grid.
- **Theme.** **View › Themes**, then pick one — the project ships with no theme
  override, so Power BI applies its current default.

## 5. Save and export for submission

1. **File › Save as**, with **Power BI files (\*.pbix)** chosen in the file-type box,
   writes `src/bi/HBOMax.pbix`: one file holding the model, the 27 visuals and a copy
   of the data, which is what most submissions want.
2. **File › Save** instead keeps the project as text, so the diff stays readable.
3. **File › Export › Export to PDF** for `src/bi/HBOMax.pdf`, so reviewers without
   Power BI Desktop can read the report.
4. Screenshot each page into `docs/report/` and link them from the README.

## 6. Optional: star-schema model with the DAX measures

This is an extra beyond the requirements, so it counts toward bonus points. It shows
the warehouse used as a proper model rather than through pre-built views.

1. **Get data** again and load the 10 `dw.Dim*` and 5 `dw.Fact*` tables.
2. In **Model view**, create one-to-many, single-direction relationships from each
   dimension key to the matching fact key. For role-playing dates, keep **one active**
   relationship per fact (e.g. `FactRevenue[PaymentDateKey]`) and leave the rest
   inactive.
3. Mark `DimDate` as the date table: **Table tools › Mark as date table › FullDate**.
4. Paste the measures from `src/bi/measures.dax` into the home tables named in each
   section of that file.
5. Add a page "KPI overview" with cards for `[Total Hours Watched]`,
   `[Monthly Recurring Revenue]`, `[Churn Rate]` and `[Titles Expiring Soon]`, plus a
   slicer on `DimDate[YearNumber]`.
