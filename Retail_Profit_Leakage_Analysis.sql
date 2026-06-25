CREATE DATABASE MyNewDatabase;
USE MyNewDatabase;
select * from products_cleaned;
select * from customers_cleaned;
select * from vendors_cleaned;
select * from inventory_cleaned;
select * from promotions_cleaned;
select * from sales_cleaned;
-- Replace invalid Promo_IDs with NULL
UPDATE sales_cleaned
SET Promo_ID = NULL
WHERE Promo_ID NOT IN (
    SELECT Promo_ID
    FROM promotions_cleaned
);
select * from returns_cleaned;


INSERT INTO products_cleaned (
    SKU_ID,
    SKU_Name,
    Category,
    Sub_Category,
    Brand,
    Tax_Percent,
    Unit_Cost,
    MRP
)

SELECT DISTINCT
    s.SKU_ID,
    'Missing Product Master' AS SKU_Name,
    'Unknown' AS Category,
    'Unknown' AS Sub_Category,
    'Unknown' AS Brand,
    NULL AS Tax_Percent,
    NULL AS Unit_Cost,
    NULL AS MRP

FROM sales_cleaned s

LEFT JOIN products_cleaned p
ON s.SKU_ID = p.SKU_ID

WHERE p.SKU_ID IS NULL;

INSERT INTO customers_cleaned (Customer_ID)
SELECT DISTINCT s.Customer_ID
FROM sales_cleaned s
LEFT JOIN customers_cleaned c ON s.Customer_ID = c.Customer_ID
WHERE c.Customer_ID IS NULL 
  AND s.Customer_ID IS NOT NULL;

--Sales → Products
ALTER TABLE sales_cleaned
ADD CONSTRAINT FK_sales_products
FOREIGN KEY (SKU_ID)
REFERENCES products_cleaned(SKU_ID);

ALTER TABLE sales_cleaned 
ALTER COLUMN Promo_ID NVARCHAR(50);

--- Sales → Promotions
ALTER TABLE sales_cleaned
ADD CONSTRAINT FK_sales_promotions
FOREIGN KEY (Promo_ID)
REFERENCES promotions_cleaned(Promo_ID);

DELETE FROM returns_cleaned
WHERE Order_ID NOT IN (SELECT Order_ID FROM sales_cleaned);
---Returns → Sales
ALTER TABLE returns_cleaned
ADD CONSTRAINT FK_returns_sales
FOREIGN KEY (Order_ID)
REFERENCES sales_cleaned(Order_ID);
---Returns → Products
ALTER TABLE returns_cleaned
ADD CONSTRAINT FK_returns_products
FOREIGN KEY (SKU_ID)
REFERENCES products_cleaned(SKU_ID);


--  722 missing SKUs and insert them into the product master
INSERT INTO products_cleaned (SKU_ID)
SELECT DISTINCT i.SKU_ID
FROM inventory_cleaned i
LEFT JOIN products_cleaned p ON i.SKU_ID = p.SKU_ID
WHERE p.SKU_ID IS NULL 
  AND i.SKU_ID IS NOT NULL;

--  Foreign Key relationship between Inventory and Products
ALTER TABLE inventory_cleaned
ADD CONSTRAINT FK_inventory_products
FOREIGN KEY (SKU_ID)
REFERENCES products_cleaned(SKU_ID);


-- unique SKUs from the vendors table that aren't in the product  yet
INSERT INTO products_cleaned (SKU_ID)
SELECT DISTINCT v.SKU_ID
FROM vendors_cleaned v
LEFT JOIN products_cleaned p ON v.SKU_ID = p.SKU_ID
WHERE p.SKU_ID IS NULL 
  AND v.SKU_ID IS NOT NULL;

--- Foreign Key relationship between Vendors and Products
ALTER TABLE vendors_cleaned
ADD CONSTRAINT FK_vendors_products
FOREIGN KEY (SKU_ID)
REFERENCES products_cleaned(SKU_ID);

ALTER TABLE vendors_cleaned
ADD CONSTRAINT FK_vendors_products
FOREIGN KEY (SKU_ID)
REFERENCES products_cleaned(SKU_ID);
---QUESTION 1
----Top 10 profit leaking SKUs
SELECT TOP 10 
    s.SKU_ID,
    p.SKU_Name,
    p.Category,
    COUNT(r.Return_ID) AS Total_Returns,
    SUM(r.Refund_Amount) AS Total_Refunded_Amount,
    (SUM(CAST(r.Refund_Amount AS DECIMAL(18,2))) - SUM(CAST(s.Quantity * p.Unit_Cost AS DECIMAL(18,2)))) AS Net_Profit_Loss
FROM sales_cleaned s
INNER JOIN products_cleaned p ON s.SKU_ID = p.SKU_ID
INNER JOIN returns_cleaned r ON s.Order_ID = r.Order_ID AND s.SKU_ID = r.SKU_ID
WHERE r.Return_Status LIKE '%Approved%'
GROUP BY s.SKU_ID, p.SKU_Name, p.Category
ORDER BY Net_Profit_Loss DESC;

---QUESTION 2
---Stores with highest discount abuse
SELECT 
    Store_ID,
    COUNT(Order_ID) AS Total_Orders,
    SUM(Discount_Amount) AS Total_Discounts_Given,
    SUM(Selling_Price * Quantity) AS Gross_Revenue,
    (SUM(Discount_Amount) / NULLIF(SUM(Selling_Price * Quantity), 0)) * 100 AS Discount_To_Revenue_Ratio
FROM sales_cleaned
GROUP BY Store_ID
ORDER BY Total_Discounts_Given DESC;


---QUESTION 3
---Category-Wise Return Contribution to Loss
WITH TotalLoss AS (
    SELECT SUM(Refund_Amount) AS Global_Total_Refunded FROM returns_cleaned WHERE Return_Status = 'Approved'
)
SELECT 
    p.Category,
    COUNT(r.Return_ID) AS Return_Count,
    SUM(r.Refund_Amount) AS Category_Refund_Loss,
    (SUM(r.Refund_Amount) / (SELECT Global_Total_Refunded FROM TotalLoss)) * 100 AS Percent_Contribution_To_Total_Loss
FROM returns_cleaned r
INNER JOIN products_cleaned p ON r.SKU_ID = p.SKU_ID
WHERE r.Return_Status = 'Approved'
GROUP BY p.Category
ORDER BY Category_Refund_Loss DESC;

---QUESTION 4 
---Promotion-wise profitability ranking
SELECT 
    s.Promo_ID,
    p.Promo_Type,
    p.Promo_Budget,
    SUM(s.Selling_Price * s.Quantity) AS Generated_Revenue,
    SUM(s.Discount_Amount) AS Discount_Cost,
    (SUM(s.Selling_Price * s.Quantity) - SUM(s.Discount_Amount) - p.Promo_Budget) AS Net_Promo_Profit,
    DENSE_RANK() OVER (ORDER BY (SUM(s.Selling_Price * s.Quantity) - SUM(s.Discount_Amount) - p.Promo_Budget) DESC) AS Profitability_Rank
FROM sales_cleaned s
INNER JOIN promotions_cleaned p ON s.Promo_ID = p.Promo_ID
GROUP BY s.Promo_ID, p.Promo_Type, p.Promo_Budget;

---QUESTION 5
---Vendor delay heatmap dataset
SELECT 
    Vendor_ID,
    Store_ID,
    COUNT(PO_ID) AS Total_Purchase_Orders,
    AVG(DATEDIFF(day, Expected_Delivery_Date, Actual_Delivery_Date)) AS Avg_Days_Delayed,
    SUM(CASE WHEN Actual_Delivery_Date > Expected_Delivery_Date THEN 1 ELSE 0 END) AS Late_Deliveries_Count,
    SUM(Supplied_Quantity) AS Total_Received_Qty,
    SUM(Procurement_Cost) AS Total_Procurement_Spend
FROM vendors_cleaned
WHERE Actual_Delivery_Date IS NOT NULL
GROUP BY Vendor_ID, Store_ID

---QUESTION 6
---Stockout frequency per SKU-store
SELECT 
    Store_ID,
    SKU_ID,
    COUNT(Date) AS Stockout_Days_Count,
    AVG(Warehouse_Stock) AS Remaining_Safety_Buffer
FROM inventory_cleaned
WHERE Closing_Stock = 0
GROUP BY Store_ID, SKU_ID
ORDER BY Stockout_Days_Count DESC;

---QUESTION 7
---Customer cohorts (Month 0,1,2 repeat rate)
WITH Cohort_Base AS (
    SELECT 
        Customer_ID,
        DATETRUNC(month, Signup_Date) AS Cohort_Month
    FROM customers_cleaned
),
Customer_Activity AS (
    SELECT DISTINCT
        cb.Customer_ID,
        cb.Cohort_Month,
        DATEDIFF(month, cb.Cohort_Month, DATETRUNC(month, s.Order_Date)) AS Months_Since_Signup
    FROM sales_cleaned s
    INNER JOIN Cohort_Base cb ON s.Customer_ID = cb.Customer_ID
)
SELECT 
    Cohort_Month,
    COUNT(DISTINCT Customer_ID) AS Initial_Cohort_Size,
    SUM(CASE WHEN Months_Since_Signup = 0 THEN 1 ELSE 0 END) AS Month_0_Active,
    SUM(CASE WHEN Months_Since_Signup = 1 THEN 1 ELSE 0 END) AS Month_1_Active,
    SUM(CASE WHEN Months_Since_Signup = 2 THEN 1 ELSE 0 END) AS Month_2_Active,
    -- Retention Rates
    CAST(SUM(CASE WHEN Months_Since_Signup = 1 THEN 1 ELSE 0 END) AS FLOAT) / COUNT(DISTINCT Customer_ID) * 100 AS Month_1_Repeat_Rate,
    CAST(SUM(CASE WHEN Months_Since_Signup = 2 THEN 1 ELSE 0 END) AS FLOAT) / COUNT(DISTINCT Customer_ID) * 100 AS Month_2_Repeat_Rate
FROM Customer_Activity
GROUP BY Cohort_Month
ORDER BY Cohort_Month;

---QUESTION 8
---RFM scoring using SQL
WITH RFM_Base AS (
    SELECT 
        Customer_ID,
        -- Recency: Days elapsed between latest invoice date and the base dataset max date
        DATEDIFF(day, MAX(Order_Date), (SELECT MAX(Order_Date) FROM sales_cleaned)) AS Recency_Days,
        -- Frequency: Total transactional frequency count
        COUNT(DISTINCT Order_ID) AS Frequency_Count,
        -- Monetary: Aggregate absolute cash pipeline valuation
        SUM(Selling_Price * Quantity) AS Monetary_Value
    FROM sales_cleaned
    GROUP BY Customer_ID
),
RFM_Scores AS (
    SELECT 
        Customer_ID,
        Recency_Days,
        Frequency_Count,
        Monetary_Value,
        -- Recency: Lower values get higher score (1 is oldest, 5 is most recent)
        NTILE(5) OVER (ORDER BY Recency_Days DESC) AS R_Score,
        -- Frequency & Monetary: Higher values get higher scores
        NTILE(5) OVER (ORDER BY Frequency_Count ASC) AS F_Score,
        -- Monetary score distribution
        NTILE(5) OVER (ORDER BY Monetary_Value ASC) AS M_Score
    FROM rfm_base
)
SELECT 
    Customer_ID,
    Recency_Days,
    Frequency_Count,
    Monetary_Value,
    R_Score,
    F_Score,
    M_Score,
    -- Concatenated aggregate string score profile (e.g., '554')
    CONCAT(R_Score, F_Score, M_Score) AS RFM_Cell_Profile
FROM RFM_Scores;