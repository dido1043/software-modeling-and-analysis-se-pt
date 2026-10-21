# Power BI report: build guide

This guide covers course requirement 5: a report with at least 4 visualizations, built on data from your own database.

The report has **5 pages and 12 visuals**. Each visual reads one analytic view from `src/dw/15_dw_analytic_views.sql`. Every view was designed for a specific visual (see the `CONSUMED BY` note above each view), so you don't have to write any DAX. `src/bi/measures.dax` is optional and only needed for the extras in step 6.

> Power BI Desktop runs on **Windows only**. Build the report on the Windows laptop, against the same SQL Server instance where you ran scripts 01–16.

---

## 1. Prerequisites

1. Run scripts `01`–`16` in order (see the README).
2. Check result set 5 of `16_run_full_load.sql`. All seven views must return more than 0 rows. If a view is empty, its page will be blank.

## 2. Connect and load

1. Open Power BI Desktop and go to **Home › Get data › SQL Server**.
2. Set **Server** to `localhost` (or your instance name, e.g. `localhost\SQLEXPRESS`), **Database** to `HBOMaxDW`, and **Data connectivity mode** to **Import**.
3. In the Navigator, under `dw`, tick these seven views and click **Load**:
   - `vw_ViewingTrendByMonthRegion`
   - `vw_TopTitlesByHoursWatched`
   - `vw_RevenueAndMrrByPlan`
   - `vw_ChurnByCohort`
   - `vw_GenreEngagementByDayPart`
   - `vw_DeviceMixByRegion`
   - `vw_OriginalsVsLicensedPerformance`
4. Set the sort columns so months and day parts appear in order instead of A–Z. In **Data view**, select the column, then choose **Column tools › Sort by column**:

   | Table | Column | Sort by |
   |---|---|---|
   | vw_ViewingTrendByMonthRegion | MonthLabel | MonthKey |
   | vw_RevenueAndMrrByPlan | MonthLabel | MonthKey |
   | vw_ChurnByCohort | CohortLabel | CohortMonthKey |
   | vw_ChurnByCohort | ActivityMonthLabel | ActivityMonthKey |
   | vw_GenreEngagementByDayPart | DayPart | DayPartSortOrder |

5. Turn off auto-aggregation for the key columns. On every `*Key` / `*ID` column, set **Column tools › Summarization** to **Don't summarize**.

The views are pre-aggregated and self-contained, so **no relationships are needed**. Delete any relationships Power BI auto-detects (**Model view**), so one page's filters don't leak into another.

## 3. Pages and visuals

### Page 1: Viewing overview

| # | Visual | Table | Fields |
|---|---|---|---|
| 1 | **Card** ×3 | vw_ViewingTrendByMonthRegion | `HoursWatched` (Sum), `SessionCount` (Sum), `BingeSessionCount` (Sum). All three add up correctly across months and regions |
| 2 | **Line chart**: "Hours watched by month and region" | vw_ViewingTrendByMonthRegion | X-axis `MonthLabel` · Y-axis `HoursWatched` · Legend `RegionName` |
| 3 | **Matrix with heat map**: "Genre × day part" | vw_GenreEngagementByDayPart | Rows `GenreName` · Columns `DayPart` · Values `HoursWatched`. Then **Format › Cell elements › Background color: on** (gradient). Tooltip `AvgCompletionPct` |
| – | Slicer | vw_ViewingTrendByMonthRegion | `CalendarYear` |

### Page 2: Content performance

| # | Visual | Table | Fields |
|---|---|---|---|
| 4 | **Clustered bar chart**: "Top 20 titles by hours watched" | vw_TopTitlesByHoursWatched | Y-axis `TitleName` · X-axis `HoursWatched`. Filter pane: `HoursRank` **is less than or equal to 20** |
| 5 | **Table**: title detail | vw_TopTitlesByHoursWatched | `TitleName`, `PrimaryGenre`, `ContentSource`, `UniqueViewers`, `CompletionRatePct`, `AvgRating`, same filter `HoursRank ≤ 20` |
| 6 | **Clustered column chart**: "Originals vs licensed" | vw_OriginalsVsLicensedPerformance | X-axis `ContentSource` · Y-axis `ShareOfHoursPct` and `CatalogueSharePct` |

### Page 3: Revenue and plans

| # | Visual | Table | Fields |
|---|---|---|---|
| 7 | **Line and stacked column chart**: "Recognised revenue and MRR by month" | vw_RevenueAndMrrByPlan | X-axis `MonthLabel` · Column y-axis `RecognisedRevenue` · Column legend `PlanName` · Line y-axis `Mrr` |
| 8 | **Matrix**: "ARPU by plan by month" | vw_RevenueAndMrrByPlan | Rows `PlanName` · Columns `MonthLabel` · Values `ArpuRecognised` (Sum, since there is one row per plan and month) |
| – | Card | vw_RevenueAndMrrByPlan | `PaymentFailureRatePct` (Average) |

### Page 4: Retention

| # | Visual | Table | Fields |
|---|---|---|---|
| 9 | **Matrix: cohort triangle** with heat map | vw_ChurnByCohort | Rows `CohortLabel` · Columns `MonthsSinceSignup` · Values `RetentionVsCohortStartPct` (Sum). Background color: gradient, red (low) to green (high) |
| 10 | **Line chart**: "Churn rate by activity month" | vw_ChurnByCohort | X-axis `ActivityMonthLabel` · Y-axis `SubscribersChurned` and `SubscriptionsObserved` (Sum) |

### Page 5: Devices and quality

| # | Visual | Table | Fields |
|---|---|---|---|
| 11 | **100% stacked bar chart**: "Device mix by region" | vw_DeviceMixByRegion | Y-axis `RegionName` · X-axis `HoursWatched` · Legend `FormFactor` |
| 12 | **Clustered column chart**: "Buffering events per hour" | vw_DeviceMixByRegion | X-axis `FormFactor` · Y-axis `BufferingEventsPerHour` (Average) · Legend `RegionName` |

## 4. Finishing touches

- Give each page a title text box that matches its page name.
- Use one theme for the whole report: **View › Themes**, with a dark theme such as *Executive* or *Innovate*.
- Hover over a few bars and cells to check that the tooltips show sensible numbers.

## 5. Save and export for submission

1. Save the report as `report/HBOMax.pbix`, in a new `report/` folder at the project root.
2. Use **File › Export › Export to PDF** to save `report/HBOMax.pdf`. Reviewers who don't have Power BI Desktop can open the PDF.
3. Take a screenshot of each page into `docs/report/` (e.g. `page1-viewing.png`) and link them from the README.

## 6. Optional: star-schema model with the DAX measures

This is an extra beyond the requirements, so it counts toward bonus points. It shows the warehouse used as a proper model rather than through pre-built views.

1. **Get data** again and load the 10 `dw.Dim*` tables and 5 `dw.Fact*` tables.
2. In **Model view**, create one-to-many, single-direction relationships from each dimension key to the matching fact key. For role-playing dates, keep **one active** relationship per fact (e.g. `FactRevenue[PaymentDateKey]`) and mark the others inactive.
3. Mark `DimDate` as the date table: **Table tools › Mark as date table › FullDate**.
4. Paste the measures from `src/bi/measures.dax` into the home tables named in each section of that file.
5. Add a page "KPI overview" with cards for `[Total Hours Watched]`, `[Monthly Recurring Revenue]`, `[Churn Rate]` and `[Titles Expiring Soon]`, plus a slicer on `DimDate[YearNumber]`.
