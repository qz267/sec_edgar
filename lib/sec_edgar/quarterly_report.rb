# FIXME put this function somewhere else
def traverse_for_table(next_elem, depth)
  return next_elem if (next_elem.name == "table")
  return nil if (depth == 0)
  tmp = next_elem.next
  return traverse_for_table(tmp,              depth-1) if !tmp.nil?
  return traverse_for_table(next_elem.parent, depth-1)
end

class String
  def match_regexes(regex_arr)
    regex_arr.each do |cur_regex|
      if self =~ cur_regex
        return true
      end
    end
    return false
  end
end

module SecEdgar

  class QuarterlyReport # this can also load an annual report
    SEARCH_DEPTH = 20

    BAL_SHEET_REGEXES = 
      [/consolidated[ \n\r]*balance[ \n\r]*sheet[s]*/,
       /condensed[ \n\r]*balance[ \n\r]*sheet[s]*/,
       /balance[ \n\r]*sheet[s]*/ ]

    INC_STMT_REGEXES = 
      [/consolidated[ \n\ra-z]*statement[s]*[ \n\r]of[ \n\r]income/,
       /statement[s]*[ \n\r]of[ \n\r]consolidated[ \r\n]income/,
       /consolidated[ \n\ra-z]*statement[s]*[ \n\r]of[ \n\r]operations/,
       /income[ \n\r]*statement[s]*/ ]

    CASH_FLOW_STMT_REGEXES = 
      [/consolidated[ \n\rA-Za-z]*statement[s]*[ \n\r]of[ \n\r]cash[ \n\r]flows/,
       /statement[s]*[ \n\r]of[ \n\r]consolidated[ \n\r]cash[ \n\r]flows/,
       /cash[ \n\r]flows[ \n\r]statement[s]*/ ]

    attr_accessor :log, :bal_sheet, :inc_stmt, :cash_flow_stmt
  
    def initialize
      @bal_sheet = nil
      @inc_stmt = nil
      @cash_flow_stmt = nil
    end

    def get_summary
      fss = FinancialStatementSummary.new

      # choose which indices to use (not all reports will the same set of dates, or be sorted
      # in the same direction.  Find common ones, then sort them ascending chronologically.)
      a = @bal_sheet.report_dates
      b = @inc_stmt.report_dates
      c = (a + b).sort.uniq.keep_if { |x| !a.index(x).nil? and !b.index(x).nil? }
      bsidx = c.collect { |x| a.index(x) } # indices of balance sheet columns
      isidx = c.collect { |x| b.index(x) } # indices of income statement columns

      fss.report_dates = @bal_sheet.report_dates.values_at(*bsidx)

      fss.oa  = @bal_sheet.total_oa.cols.values_at(*bsidx)
      fss.ol  = @bal_sheet.total_ol.cols.values_at(*bsidx)
      fss.noa = @bal_sheet.noa.cols.values_at(*bsidx)
      fss.fa  = @bal_sheet.total_fa.cols.values_at(*bsidx)
      fss.fl  = @bal_sheet.total_fl.cols.values_at(*bsidx)
      fss.nfa = @bal_sheet.nfa.cols.values_at(*bsidx)
      fss.cse = @bal_sheet.cse.cols.values_at(*bsidx)

      fss.composition_ratio = @bal_sheet.noa.cols.values_at(*bsidx).zip(@bal_sheet.cse.cols.values_at(*bsidx)).collect { |x,y| x/y }
      fss.noa_growth = [nil] + calc_growth_rates(@bal_sheet.noa.cols.values_at(*bsidx))
      fss.cse_growth = [nil] + calc_growth_rates(@bal_sheet.cse.cols.values_at(*bsidx))

      fss.operating_revenue       = @inc_stmt.re_operating_revenue.cols.values_at(*isidx)
      fss.gross_margin            = @inc_stmt.re_gross_margin.cols.values_at(*isidx)
      fss.oi_from_sales_after_tax = @inc_stmt.re_operating_income_from_sales_after_tax.cols.values_at(*isidx)
      fss.oi_after_tax            = @inc_stmt.re_operating_income_after_tax.cols.values_at(*isidx)
      fss.financing_income        = @inc_stmt.re_net_financing_income_after_tax.cols.values_at(*isidx)
      fss.net_income              = @inc_stmt.re_net_income.cols.values_at(*isidx)

      fss.gm            = calc_ratios(@inc_stmt.re_gross_margin.cols.values_at(*isidx),                          @inc_stmt.re_operating_revenue.cols.values_at(*isidx))
      fss.sales_pm      = calc_ratios(@inc_stmt.re_operating_income_from_sales_after_tax.cols.values_at(*isidx), @inc_stmt.re_operating_revenue.cols.values_at(*isidx))
      fss.pm            = calc_ratios(@inc_stmt.re_operating_income_after_tax.cols.values_at(*isidx),            @inc_stmt.re_operating_revenue.cols.values_at(*isidx))
      fss.fi_over_sales = calc_ratios(@inc_stmt.re_net_financing_income_after_tax.cols.values_at(*isidx),        @inc_stmt.re_operating_revenue.cols.values_at(*isidx))
      fss.ni_over_sales = calc_ratios(@inc_stmt.re_net_income.cols.values_at(*isidx),                            @inc_stmt.re_operating_revenue.cols.values_at(*isidx))

      fss.sales_over_noa = calc_ratios(@inc_stmt.re_operating_revenue.cols.values_at(*isidx), @bal_sheet.noa.cols.values_at(*bsidx))
      fss.revenue_growth = [nil] + calc_growth_rates(@inc_stmt.re_operating_revenue.cols.values_at(*isidx))
      fss.core_oi_growth = [nil] + calc_growth_rates(@inc_stmt.re_operating_income_from_sales_after_tax.cols.values_at(*isidx))
      fss.oi_growth      = [nil] + calc_growth_rates(@inc_stmt.re_operating_income_after_tax.cols.values_at(*isidx))
      fss.fi_over_nfa    = calc_ratios(@inc_stmt.re_net_financing_income_after_tax.cols.values_at(*isidx), @bal_sheet.nfa.cols.values_at(*bsidx))
      fss.re_oi          = [nil] + calc_reois(@inc_stmt.re_operating_income_after_tax.cols.values_at(*isidx), @bal_sheet.noa.cols.values_at(*bsidx))

      return fss

    end

    def parse(filename)
  
      @log.info("parsing 10q from #{filename}") if @log

      begin
        fh = File.open(filename, "r")
        doc = Hpricot(fh)
        fh.close
      rescue
        return false
      end      

      elems = doc.search("b") + doc.search("p") + doc.search("font")

      # assumes the regexes are in descending priority. searches document for 
      # each one until you find first one.
      cur_regexes = Array.new(BAL_SHEET_REGEXES)
      while not cur_regexes.empty?
        cur_regex = cur_regexes.shift
        @log.debug("trying to match balance sheet regex \"#{cur_regex}\"") if @log
        elems.each do |elem|
          # match to see if this element contains the regex in question
          if bal_sheet.nil? and elem.inner_text.downcase =~ cur_regex
            @log.debug("matched bal sheet regex at tag \"#{elem.inner_text}\"") if @log
            table_elem = traverse_for_table(elem, SEARCH_DEPTH)
            if not table_elem.nil? 
              @log.info("parsing balance sheet, at tag \"#{elem.inner_text}\"") if @log
              @bal_sheet = BalanceSheet.new
              @bal_sheet.log = @log if @log
              if @bal_sheet.parse(table_elem) == false
                @log.info("failed to parse balance sheet, resetting to try again.") if @log
                @bal_sheet = nil # discard bogus parse attempts
              else
                @log.info("parsing of balance sheet succeeded") if @log
                cur_regexes = [] # done
              end
            end
          end
        end
      end
      raise "Failed to parse balance sheet from #{filename}" if @bal_sheet.nil?

      # assumes the regexes are in descending priority. searches document for 
      # each one until you find first one.
      cur_regexes = Array.new(INC_STMT_REGEXES)
      while not cur_regexes.empty?
        cur_regex = cur_regexes.shift
        @log.debug("trying to match income statement regex \"#{cur_regex}\"") if @log
        elems.each do |elem|
          # match to see if this element contains the regex in question
          if inc_stmt.nil? and elem.inner_text.downcase =~ cur_regex
            @log.debug("matched income stmt regex at tag \"#{elem.inner_text}\"") if @log
            table_elem = traverse_for_table(elem, SEARCH_DEPTH)
            if not table_elem.nil? 
              @log.info("parsing income stmt, at tag \"#{elem.inner_text}\"") if @log
              @inc_stmt = IncomeStatement.new
              @inc_stmt.log = @log if @log
              if @inc_stmt.parse(table_elem) == false
                @inc_stmt = nil # discard bogus parse attempts
              else
                @log.info("parsing of income stmt succeeded") if @log
                cur_regexes = [] # done
              end
            end
          end
        end
      end
      raise "Failed to parse income statement from #{filename}" if @inc_stmt.nil?

      # assumes the regexes are in descending priority. searches document for 
      # each one until you find first one.
      cur_regexes = Array.new(CASH_FLOW_STMT_REGEXES)
      while not cur_regexes.empty?
        cur_regex = cur_regexes.shift
        @log.debug("trying to match cash flow statement regex \"#{cur_regex}\"") if @log
        elems.each do |elem|
          # match to see if this element contains the regex in question
          if @cash_flow_stmt.nil? and elem.inner_text.downcase =~ cur_regex
            @log.debug("matched cash flow stmt regex at tag \"#{elem.inner_text}\"") if @log
            table_elem = traverse_for_table(elem, SEARCH_DEPTH)
            if not table_elem.nil? 
              @log.info("parsing cash flow stmt, at tag \"#{elem.inner_text}\"") if @log
              @cash_flow_stmt = CashFlowStatement.new
              @cash_flow_stmt.log = @log if @log
              if @cash_flow_stmt.parse(table_elem) == false
                @cash_flow_stmt = nil # discard bogus parse attempts
              else
                @log.info("parsing of cash flow stmt succeeded") if @log
                cur_regexes = [] # done
              end
            end
          end
        end
      end
      raise "Failed to parse cash flow statement from #{filename}" if @cash_flow_stmt.nil?

      return false if (@bal_sheet == nil) or (@inc_stmt == nil) or (@cash_flow_stmt == nil)
      return true
    end

    # Helpers for write_summary

    def calc_growth_rates(a)
      a[0..(a.length-2)].zip(a[1..a.length]).collect { |x,y| (Float(y)-x)/x }
    end

    def calc_ratios(a, b)
      a.zip(b).collect{ |x,y| Float(x)/y }
    end

    def calc_reois(ois, noas)
      ois[1..(ois.length-1)].zip(noas[0..(noas.length-2)]).collect { |oi,noa| Float(oi)-(0.1*noa) }
    end

  end
  
end
