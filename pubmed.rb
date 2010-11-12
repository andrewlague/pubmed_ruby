require 'nokogiri'

class Pubmed
  attr_reader :article_xml

  URL_IDENTIFIERS = '&tool=biophotonicsworld&email=' + CGI.escape('contactus@biophotonicsworld.org')

  RETURN_MODE = '&retmode=xml'

  ESEARCH_BASE_URL = 'http://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi?db=pubmed' +
          URL_IDENTIFIERS + RETURN_MODE

  EFETCH_BASE_URL = 'http://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi?db=pubmed' +
          URL_IDENTIFIERS + RETURN_MODE

  ELINK_BASE_URL = 'http://eutils.ncbi.nlm.nih.gov/entrez/eutils/elink.fcgi?cmd=neighbor_score' +
          URL_IDENTIFIERS + RETURN_MODE

  def self.harvest_from_search(terms, options = { :reload => false })
    result_ids = ids_from_search(terms)
    if options[:reload]
      fetch_ids = result_ids
    else
      fetch_ids = select_ids_not_in_database_from(result_ids)
    end
    instances_from_ids(fetch_ids).each do |article|
      article.save_journal_article
    end
    { :created => fetch_ids, :already_existed_locally => result_ids - fetch_ids }
  end

  def self.select_ids_not_in_database_from(pubmed_ids)
    return [] unless pubmed_ids.any?
    existing_ids = JournalArticle.all(:select => 'pmid',
                                      :conditions => "pmid IN ( #{pubmed_ids.map{|i| "'#{i}'"}.
                                              join(',')} )").map(&:pmid)
    pubmed_ids - existing_ids
  end

  def self.instances_from_search(terms)
    pubmed_ids = ids_from_search terms
    instances_from_ids pubmed_ids
  end

  def self.ids_from_search(terms)
    begin
      xml = Nokogiri::XML(open(ESEARCH_BASE_URL + '&term=' + CGI.escape(terms)))
    rescue => e
      raise PubMedConnectionError.new("PubMedConnectionError: " + e)
    end
    xml.css('Id').map{ |id_tag| id_tag.content }
  end

  def self.xml_from_search(terms)
    xml_from_ids(ids_from_search(terms))
  end

  def self.instance_from_id(id)
    xml = xml_from_ids([id])
    instances_from_xml(xml).first
  end

  def self.instances_from_ids(pmids)
    xml = xml_from_ids pmids
    instances_from_xml xml
  end

  def self.instances_from_xml(article_xml)
    article_xml.map{ |ax| Pubmed.new ax }
  end

  def self.xml_from_ids(pubmed_ids)
    return [] if pubmed_ids.empty?
    pubmed_ids = pubmed_ids.join(',') if pubmed_ids.respond_to? :join
    begin
      xml = Nokogiri::XML(open(EFETCH_BASE_URL + '&id=' + pubmed_ids))
    rescue => e
      raise PubMedConnectionError.new("PubMedConnectionError: " + e)
    end
    xml.css('PubmedArticle')
  end

  def self.create_articles_from_ids(ids, options = { :reload => false })
    if options[:reload]
      fetch_ids = ids
    else
      fetch_ids = Pubmed.select_ids_not_in_database_from(ids)
    end
    puts "Fetching IDs from PubMed: #{fetch_ids.join(', ')}" if fetch_ids.any?
    new_instances = Pubmed.instances_from_ids(fetch_ids)
    new_instances.each{ |instance| instance.save_journal_article }
  end


  def initialize(id)
    if id.respond_to? :css
      @article_xml = id
    else
      @article_xml = Pubmed.xml_from_ids(id.to_s).first
    end
  end

  def inspect
    self.to_s + ' ' + title 
  end

  def related_pubmed_ids_to_scores
    returning ids_to_scores = [] do
      begin
        xml = Nokogiri::XML(open(ELINK_BASE_URL + '&id=' + pmid))
      rescue => e
        raise PubMedConnectionError.new("PubMedConnectionError: " + e)
      end
      xml.css('LinkSetDb').each do |link_set_db|
        if link_set_db.css('DbTo').inner_text == 'pubmed' &&
                link_set_db.css('LinkName').inner_text == 'pubmed_pubmed'
          link_set_db.css('Link').each do |link|
            id = link.css('Id').inner_text
            score = link.css('Score').inner_text
            ids_to_scores << { :id => id, :score => score }
          end
        end
      end
    end
  end

  def create_links_with_article_ids_to_scores(ids_to_scores)
    ids_to_scores.each do |hash|
      related_article_id = hash[:id]
      next if related_article_id == pmid
      id1 = related_article_id.to_i < pmid.to_i ? related_article_id : pmid
      id2 = related_article_id.to_i < pmid.to_i ? pmid : related_article_id
      begin
        PubmedPubmedLink.create!(
                :pubmed_id1 => id1,
                :pubmed_id2 => id2,
                :score => hash[:score]
        )
      rescue ActiveRecord::RecordInvalid => e
        raise e unless e.to_s =~ /Pubmed id1 already has a link to Pubmed id2/
      end
    end
  end

  def harvest_related_articles
    related_ids_to_scores = related_pubmed_ids_to_scores
    related_ids = related_ids_to_scores.map{ |x| x[:id] }
    Pubmed.create_articles_from_ids(related_ids)
    create_links_with_article_ids_to_scores(related_ids_to_scores)
  end

  def save_journal_article
    if ja = JournalArticle.find_by_pmid(pmid) # do we already have an article with that PubMed ID?
      update_existing_journal_article
    else
      create_new_journal_article
    end
  end

  def create_new_journal_article
    JournalArticle.create!(
            :pubmed_xml => @article_xml,
            :pmid => pmid,
            :date => date,
            :journal_name => journal_name,
            :volume => volume,
            :issue => issue,
            :title => title,
            :pages => pages,
            :abstract => abstract,
            :authors => authors,
            :affiliations => affiliations,
            :publication_type => publication_type,
            :doi => doi,
            :pubmed_status => pubmed_status
    )
  end

  def update_existing_journal_article
    JournalArticle.find_by_pmid(pmid).update_attributes!(
            :pubmed_xml => @article_xml,
            :pmid => pmid,
            :date => date,
            :journal_name => journal_name,
            :volume => volume,
            :issue => issue,
            :title => title,
            :pages => pages,
            :abstract => abstract,
            :authors => authors,
            :affiliations => affiliations,
            :publication_type => publication_type,
            :doi => doi,
            :pubmed_status => pubmed_status
    )
  end

  def pmid
    grab_first_node 'PMID'
  end

  def date
    begin
      Date.parse @article_xml.css('PubDate').first.inner_text
    rescue
      year = grab_first_node('PubDate Year')
      year = '1900' if year.blank?
      if month = grab_first_node('PubDate Month')
      else
        month = 'Jan'
      end
      year + ' ' + month
    end
  end

  def journal_name
    grab_first_node 'Journal Title'
  end

  def volume
    grab_first_node 'JournalIssue Volume'
  end

  def issue
    grab_first_node 'JournalIssue Issue'
  end

  def title
    grab_first_node 'ArticleTitle'
  end

  def pages
    grab_first_node 'MedlinePgn'
  end

  def abstract
    grab_first_node 'Abstract'
  end

  def authors
    @article_xml.css('AuthorList Author').map do |author|
      first_name = author.css('FirstName').inner_text
      if first_name.blank?
        first_name = author.css('ForeName').inner_text
      end
      first_name + ' ' + author.css('LastName').inner_text
    end.join(', ')
  end

  def affiliations
    grab_first_node 'Affiliation'
  end

  def publication_type
    @article_xml.css('PublicationTypeList').map do |type|
      type.inner_text.strip
    end.join(', ')
  end

  def doi
    grab_first_node 'ArticleId[IdType=doi]'
  end

  # A status of "MEDLINE" means the article has been reviewed an indexed into MeSH keywords,
  # chemicals used, etc.  A status of "Publisher" means just the basics are there (abstract,
  # journal info, etc.)
  def pubmed_status
    @article_xml.css('MedlineCitation').first['Status']
  end


  private

  def grab_first_node(css_selector)
    if node = @article_xml.css(css_selector).first
      node.inner_text
    end
  end

end


class PubMedConnectionError < Exception; end
