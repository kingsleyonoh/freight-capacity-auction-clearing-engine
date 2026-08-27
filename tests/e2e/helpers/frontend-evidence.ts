import { expect, type Locator, type Page } from '@playwright/test';

const channel = (value: number) => {
  const normalized = value / 255;
  return normalized <= 0.03928 ? normalized / 12.92 : ((normalized + 0.055) / 1.055) ** 2.4;
};

const rgb = (cssColor: string) => {
  const match = cssColor.match(/rgba?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)/i);
  if (!match) throw new Error(`unsupported computed color ${cssColor}`);
  return [Number(match[1]), Number(match[2]), Number(match[3])] as const;
};

export const contrastRatio = (foreground: string, background: string) => {
  const luminance = ([red, green, blue]: readonly number[]) => 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue);
  const first = luminance(rgb(foreground));
  const second = luminance(rgb(background));
  const light = Math.max(first, second);
  const dark = Math.min(first, second);
  return (light + 0.05) / (dark + 0.05);
};

export const assertContrast = async (page: Page, selector: string, minimum: number) => {
  const colors = await page.locator(selector).evaluate((element) => {
    const style = getComputedStyle(element);
    const parentStyle = getComputedStyle(element.parentElement ?? document.body);
    const background = style.backgroundColor === 'rgba(0, 0, 0, 0)' ? parentStyle.backgroundColor : style.backgroundColor;
    return { foreground: style.color, background };
  });
  expect(contrastRatio(colors.foreground, colors.background), `${selector} contrast`).toBeGreaterThanOrEqual(minimum);
};

export const assertVisibleFocus = async (locator: Locator) => {
  await locator.focus();
  await expect(locator).toBeFocused();
  const focus = await locator.evaluate((element) => {
    const style = getComputedStyle(element);
    return { outlineStyle: style.outlineStyle, outlineWidth: Number.parseFloat(style.outlineWidth), boxShadow: style.boxShadow };
  });
  expect(focus.outlineStyle !== 'none' && focus.outlineWidth >= 2 || focus.boxShadow !== 'none').toBe(true);
};

export const assertEquivalentChartTable = async (page: Page, summarySelector: string, tableSelector: string) => {
  const summary = (await page.locator(summarySelector).innerText()).replaceAll(/\s+/g, ' ').trim();
  const rows = await page.locator(`${tableSelector} tbody tr`).allInnerTexts();
  expect(rows.length).toBeGreaterThan(0);
  for (const row of rows) {
    for (const token of row.split(/\s+/).filter((value) => /\d|Lane|Carrier/.test(value))) {
      expect(summary).toContain(token);
    }
  }
};

export const assertReducedMotion = async (page: Page, selector: string) => {
  await page.emulateMedia({ reducedMotion: 'reduce' });
  const durations = await page.locator(selector).evaluate((element) => {
    const style = getComputedStyle(element);
    return [style.animationDuration, style.transitionDuration].map((value) => Number.parseFloat(value) || 0);
  });
  expect(Math.max(...durations)).toBeLessThanOrEqual(0.01);
};
