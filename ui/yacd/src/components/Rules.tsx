import cx from 'clsx';
import React from 'react';
import { useTranslation } from 'react-i18next';
import { areEqual, VariableSizeList } from 'react-window';

import ContentHeader from '~/components/ContentHeader';
import { RuleProviderItem } from '~/components/rules/RuleProviderItem';
import { useRuleAndProvider } from '~/components/rules/rules.hooks';
import { RulesPageFab } from '~/components/rules/RulesPageFab';
import { TextFilter } from '~/components/shared/TextFitler';
import { ruleFilterText } from '~/store/rules';
import { State } from '~/store/types';
import { ClashAPIConfig } from '~/types';

import useRemainingViewPortHeight from '../hooks/useRemainingViewPortHeight';
import { getClashAPIConfig } from '../store/app';
import Rule from './Rule';
import s from './Rules.module.scss';
import { connect } from './StateProvider';

const { memo, useState, useCallback } = React;

type ItemData = {
  rules: any[];
  provider: any;
  apiConfig: ClashAPIConfig;
};

function itemKey(index: number, { rules, provider }: ItemData) {
  if (!rules) {
    return provider.names[index];
  }
  return rules[index].id;
}

function getItemSizeFactory({ isRulesTab }) {
  return function getItemSize() {
    if (!isRulesTab) {
      // provider
      return 100;
    }
    // rule
    return 70;
  };
}

// @ts-expect-error ts-migrate(2339) FIXME: Property 'index' does not exist on type '{ childre... Remove this comment to see the full error message
const Row = memo(({ index, style, data }) => {
  const { rules, provider, apiConfig } = data;

  if (!rules) {
    const name = provider.names[index];
    const item = provider.byName[name];
    return (
      <div style={style} className={s.RuleProviderItemWrapper}>
        <RuleProviderItem apiConfig={apiConfig} {...item} />
      </div>
    );
  }

  const r = rules[index];
  return (
    <div style={style}>
      <Rule {...r} />
    </div>
  );
}, areEqual);

const mapState = (s: State) => ({
  apiConfig: getClashAPIConfig(s),
});

export default connect(mapState)(Rules);

type RulesProps = {
  apiConfig: ClashAPIConfig;
};

function Rules({ apiConfig }: RulesProps) {
  const [refRulesContainer, containerHeight] = useRemainingViewPortHeight();
  const { rules, provider } = useRuleAndProvider(apiConfig);
  const [activeTab, setActiveTab] = useState('rules');

  const formatQty = (qty: number) => (qty < 100 ? '' + qty : '99+');

  const handleTabKeyDown = useCallback(
    (tab: string) => (e: React.KeyboardEvent) => {
      if (e.key === 'Enter' || e.key === ' ') {
        setActiveTab(tab);
      }
    },
    []
  );

  const isRulesTab = activeTab === 'rules';
  const getItemSize = getItemSizeFactory({ isRulesTab });

  const { t } = useTranslation();

  return (
    <div className={s.container}>
      <ContentHeader>
        <div className={s.tabsContainer}>
          <div
            className={cx(s.tab, { [s.active]: activeTab === 'rules' })}
            onClick={() => setActiveTab('rules')}
            onKeyDown={handleTabKeyDown('rules')}
            role="button"
            tabIndex={0}
          >
            {t('Rules')}
            <span className={s.tabCount}>{formatQty(rules.length)}</span>
          </div>
          {provider.names.length > 0 && (
            <div
              className={cx(s.tab, { [s.active]: activeTab === 'providers' })}
              onClick={() => setActiveTab('providers')}
              onKeyDown={handleTabKeyDown('providers')}
              role="button"
              tabIndex={0}
            >
              {t('rule_provider')}
              <span className={s.tabCount}>{formatQty(provider.names.length)}</span>
            </div>
          )}
        </div>
        <div style={{ flex: 1 }} />
        <div className={s.filterWrapper}>
          <TextFilter textAtom={ruleFilterText} placeholder={t('Search')} />
        </div>
      </ContentHeader>
      <div ref={refRulesContainer} className={s.listWrapper}>
        <VariableSizeList
          height={containerHeight}
          width="100%"
          itemCount={isRulesTab ? rules.length : provider.names.length}
          itemSize={getItemSize}
          itemData={{ rules: isRulesTab ? rules : null, provider, apiConfig }}
          itemKey={itemKey}
        >
          {Row}
        </VariableSizeList>
      </div>
      {provider && provider.names && provider.names.length > 0 ? (
        <RulesPageFab apiConfig={apiConfig} />
      ) : null}
    </div>
  );
}
